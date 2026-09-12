//! Opt-in, bounded local CPU span recording. No source text or tracing fields are captured.
use std::{cell::RefCell, collections::HashMap, fs::OpenOptions, io::{BufWriter, Write},
    sync::{Arc, Mutex, atomic::{AtomicU64, Ordering}, mpsc}, time::{Duration, Instant}};
use tracing::{span, Metadata, Subscriber, Event};
thread_local! { static ENTERED: RefCell<Vec<(u64, Instant)>> = const { RefCell::new(Vec::new()) }; }
struct Entry { name: &'static str, target: &'static str, refs: usize }
#[derive(serde::Serialize)]
struct Sample { name: &'static str, target: &'static str, start_us: u64, duration_us: u64 }
struct Recorder {
    origin: Instant, duration: Duration, ids: AtomicU64,
    spans: Mutex<HashMap<u64, Entry>>, tx: mpsc::SyncSender<Sample>, dropped: Arc<AtomicU64>,
}
impl Subscriber for Recorder {
    fn enabled(&self, m: &Metadata<'_>) -> bool {
        m.is_span() && (m.target().starts_with("readit::ui") ||
            (m.target()=="gpui::window" && matches!(m.name(), "draw" | "present")))
    }
    fn new_span(&self, a: &span::Attributes<'_>) -> span::Id {
        let id=self.ids.fetch_add(1,Ordering::Relaxed);
        self.spans.lock().unwrap().insert(id,Entry{name:a.metadata().name(),target:a.metadata().target(),refs:1});
        span::Id::from_u64(id)
    }
    fn record(&self, _: &span::Id, _: &span::Record<'_>) {}
    fn record_follows_from(&self, _: &span::Id, _: &span::Id) {}
    fn event(&self, _: &Event<'_>) {}
    fn enter(&self, id: &span::Id) { ENTERED.with(|v|v.borrow_mut().push((id.into_u64(),Instant::now()))); }
    fn exit(&self, id: &span::Id) {
        let start=ENTERED.with(|v|{let mut v=v.borrow_mut();v.iter().rposition(|(i,_)|*i==id.into_u64()).map(|i|v.remove(i).1)});
        if let Some(start)=start {
            if start.duration_since(self.origin)>self.duration {return;}
            let elapsed=start.elapsed();
            if let Some(e)=self.spans.lock().unwrap().get(&id.into_u64()) {
                let sample=Sample{name:e.name,target:e.target,start_us:start.duration_since(self.origin).as_micros() as u64,duration_us:elapsed.as_micros() as u64};
                if self.tx.try_send(sample).is_err(){self.dropped.fetch_add(1,Ordering::Relaxed);}
            }
        }
    }
    fn clone_span(&self,id:&span::Id)->span::Id { if let Some(e)=self.spans.lock().unwrap().get_mut(&id.into_u64()){e.refs+=1;} id.clone() }
    fn try_close(&self,id:span::Id)->bool {
        let mut spans=self.spans.lock().unwrap();
        if let Some(e)=spans.get_mut(&id.into_u64()){e.refs-=1;if e.refs==0{spans.remove(&id.into_u64());return true;}}
        false
    }
}

pub fn init() {
    let Some(path)=std::env::var_os("READIT_PERF") else {return;};
    let file=match OpenOptions::new().write(true).create_new(true).open(&path){Ok(f)=>f,Err(e)=>{eprintln!("performance log: {e}");return;}};
    let duration=Duration::from_secs(std::env::var("READIT_PERF_SECONDS").ok().and_then(|s|s.parse::<u64>().ok()).unwrap_or(120).clamp(1,600));
    let (tx,rx)=mpsc::sync_channel::<Sample>(8192);
    let dropped=Arc::new(AtomicU64::new(0));
    let recorder=Recorder{origin:Instant::now(),duration,ids:AtomicU64::new(1),spans:Mutex::new(HashMap::new()),tx,dropped:dropped.clone()};
    if tracing::subscriber::set_global_default(recorder).is_err(){eprintln!("performance subscriber already configured");return;}
    std::thread::spawn(move || {
        let mut writer=BufWriter::new(file);
        let header=serde_json::json!({"kind":"readit-cpu-spans","version":1,"debug_assertions":cfg!(debug_assertions),"seconds":duration.as_secs(),"pid":std::process::id()});
        let _=writeln!(writer,"{header}");
        let deadline=Instant::now()+duration+Duration::from_secs(1);
        while Instant::now()<deadline {
            match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(sample)=>{if serde_json::to_writer(&mut writer,&sample).is_err() || writeln!(writer).is_err(){return;}},
                Err(mpsc::RecvTimeoutError::Timeout)=>{if writer.flush().is_err(){return;}},
                Err(_)=>break,
            }
        }
        let _=writeln!(writer,"{}",serde_json::json!({"dropped":dropped.load(Ordering::Relaxed)}));
        let _=writer.flush();
    });
    eprintln!("Recording local CPU spans for {}s: {}",duration.as_secs(),path.to_string_lossy());
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn captures_nested_cpu_scopes_without_sensitive_fields() {
        let (tx,rx)=mpsc::sync_channel(8);
        let recorder=Recorder{origin:Instant::now(),duration:Duration::from_secs(1),ids:AtomicU64::new(1),spans:Mutex::new(HashMap::new()),tx,dropped:Arc::new(AtomicU64::new(0))};
        tracing::subscriber::with_default(recorder,|| {
            let outer=tracing::info_span!(target:"readit::ui", "render", text="private source");
            let _outer=outer.enter();
            let inner=tracing::info_span!(target:"readit::ui", "explorer");
            let cloned=inner.clone();
            let _inner=cloned.enter();
        });
        let samples=rx.try_iter().collect::<Vec<_>>();
        assert_eq!(samples.len(),2);
        assert_eq!(samples[0].name,"explorer");
        assert_eq!(samples[1].name,"render");
        let json=serde_json::to_string(&samples).unwrap();
        assert!(!json.contains("private source"));
        assert!(samples[1].duration_us>=samples[0].duration_us);
    }
}
