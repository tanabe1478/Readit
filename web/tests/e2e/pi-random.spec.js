// A reader who presses the guide buttons in random order. Starting from the
// overview, a seeded sequence of chapter, next, back, question, end and overview
// presses is replayed against the real Readit with a scripted pi session, and
// after every press the editor state and the bubble are compared with a model
// of what the tour should look like. Questions are sometimes followed by more
// presses before the model has answered. READIT_RANDOM_SEED and
// READIT_RANDOM_STEPS override the seeds and the length.
import { fauxAssistantMessage } from '@earendil-works/pi-ai';
import { test, expect } from './fixture.js';
import { startPi, call, lastResult, delivered, step, state } from './pi-harness.js';

const LINES = 6;
test.use({ files: { 'sample.py': Array.from({ length: LINES }, (_, i) => `v${i + 1} = ${i + 1}\n`).join('') } });
test.setTimeout(300_000);

const seeds = process.env.READIT_RANDOM_SEED ? process.env.READIT_RANDOM_SEED.split(',').map(Number) : [1, 2];
const length = Number(process.env.READIT_RANDOM_STEPS || 40);

/** mulberry32: small, seeded, good enough to replay a failure by its seed. */
function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const PREDICTION = 2;
const steps = Array.from({ length: LINES }, (_, i) => step(`s${i + 1}`, i + 1, `v${i + 1} = ${i + 1}`,
  i === PREDICTION ? { kind: 'prediction', prompt: `v${i + 1} はいくつ？` } : {}));
const chapterStarts = [0, 3];
const shown = (i) => (i === PREDICTION ? steps[i].prompt : steps[i].body);
const tour = (s) => ({
  workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence, steps,
  overview: { title: 'ランダム読み', summary: '六つの値', relationships: 'sample.py',
    chapters: chapterStarts.map((start, k) => ({ title: `章${k + 1}`, summary: `${steps[start].id} から`, start_step: steps[start].id })) },
});

for (const seed of seeds) {
  test(`random presses stay consistent (seed ${seed}, ${length} presses)`, async ({ page, readit }) => {
    const pi = await startPi(readit);
    const rand = random(seed);
    const pick = (items) => items[Math.floor(rand() * items.length)];
    const log = [];
    // What the tour should look like after the presses so far.
    const m = { guide: null, index: -1, visited: 0, overview: true, predicted: new Set(), pending: null, answers: new Map(), asked: 0, deliveredCount: 1 };
    const button = (act) => page.locator(`button[data-act="${act}"]`);

    const check = async () => {
      const s = await state(readit);
      expect(s.guide_tour?.id, 'the tour survives').toBe('tour');
      expect(s.overview_visible, 'overview visibility').toBe(m.overview);
      expect(s.guide_tour.visited_through, 'visited_through').toBe(m.visited);
      // The overview covers the bubble without closing it: the step stays current.
      if (m.overview) await expect(page.locator('#overview')).toContainText('ランダム読み');
      if (m.guide === null) {
        expect(s.guide, 'no bubble').toBeNull();
        await expect(page.locator('#guide')).toBeHidden();
        return;
      }
      expect(s.guide?.id, 'bubble step').toBe(steps[m.guide].id);
      expect(s.guide_tour.index, 'tour index').toBe(m.guide);
      const bubble = page.locator('#guide');
      if (m.overview) {
        await expect(bubble).toBeHidden();
        return;
      }
      await expect(bubble).toContainText(shown(m.guide));
      if (m.answers.has(m.guide)) await expect(bubble).toContainText(m.answers.get(m.guide));
      if (m.pending?.step === m.guide) await expect(bubble).toContainText(m.pending.text);
    };

    const enter = (index) => { m.guide = index; m.overview = false; m.visited = Math.max(m.visited, index); };
    const leave = (overview) => { m.guide = null; m.overview = overview; };

    /** One press, chosen from what the screen offers right now. */
    const press = async (allowed) => {
      if (m.guide === null || m.overview) {
        if (!m.overview) { log.push('overview'); await page.locator('#topbar button[data-act="overview"]').click(); m.overview = true; return; }
        const k = Math.floor(rand() * chapterStarts.length);
        log.push(`chapter ${k}`);
        await button('chapter').nth(k).click();
        enter(chapterStarts[k]);
        return;
      }
      const action = pick(allowed);
      log.push(action);
      switch (action) {
        case 'next': {
          const next = button('guide-next');
          if (steps[m.guide].kind === 'prediction' && !m.predicted.has(m.guide)) {
            await expect(next, 'Next waits for the prediction').toBeDisabled();
            const unknown = rand() < 0.3;
            log.push(unknown ? 'predict unknown' : 'predict');
            if (!unknown) await page.locator('#guide-prediction').fill(`${m.guide + 1} だと思う`);
            await button(unknown ? 'prediction-unknown' : 'prediction-record').click();
            m.predicted.add(m.guide);
            await expect(next).toBeEnabled();
            return;
          }
          await next.click();
          if (m.guide === steps.length - 1) leave(true); else enter(m.guide + 1);
          return;
        }
        case 'back': {
          const back = button('guide-back');
          if (m.guide === 0) {
            // The first step offers no Back; pressing one that exists must not move.
            if ((await back.count()) > 0 && (await back.isEnabled())) await back.click();
            return;
          }
          await back.click();
          m.guide -= 1;
          return;
        }
        case 'end':
          await button('guide-end').click();
          leave(false);
          return;
        case 'overview':
          // The overview covers the bubble; the step stays current.
          await page.locator('#topbar button[data-act="overview"]').click();
          m.overview = true;
          return;
        case 'ask': {
          const ask = button('guide-ask');
          if (m.pending) {
            await expect(ask, 'one question at a time').toBeDisabled();
            return;
          }
          const text = `質問${++m.asked}: ${steps[m.guide].id} はなぜ？`;
          const answer = `${steps[m.guide].id} への答え ${m.asked}`;
          const asked = m.guide;
          // The model's script: read the state, answer with readit_guide_revise, and retry
          // from a fresh state when the reader moved in between.
          const revise = (context) => {
            const s = lastResult(context);
            const q = delivered(context);
            return call('guide_revise', {
              workspace: s.workspace, id: 'tour', event_sequence: s.guide_event_sequence, question_sequence: q.event.sequence,
              answer, steps: steps.slice(s.guide_tour.visited_through + 1), overview: s.guide_tour.overview,
            });
          };
          const settle = (context) => {
            const result = lastResult(context);
            if (result.error) {
              log.push(`  revise retried: ${result.error}`);
              pi.faux.appendResponses([revise, settle]);
              return call('state', {});
            }
            return fauxAssistantMessage('答えました');
          };
          pi.faux.setResponses([call('state', {}), revise, settle]);
          await ask.click();
          await page.locator('#guide-question').fill(text);
          await button('guide-send').click();
          m.pending = { step: asked, text };
          // An impatient reader keeps pressing before the answer arrives.
          if (rand() < 0.5) {
            const extra = 1 + Math.floor(rand() * 2);
            for (let i = 0; i < extra; i++) {
              await press(['next', 'back', 'end', 'overview']);
            }
          }
          await pi.settled(++m.deliveredCount, 30_000);
          m.answers.set(asked, answer);
          m.pending = null;
          return;
        }
      }
    };

    try {
      await pi.turn('sample.py を読む順番を案内して', [call('state', {}), (context) => call('guide_load', tour(lastResult(context))), fauxAssistantMessage('登録しました')]);
      await expect(page.locator('#overview')).toContainText('ランダム読み');
      // Loading shows the overview with the first step already current behind it.
      const loaded = await state(readit);
      m.guide = loaded.guide ? loaded.guide_tour.index : null;
      m.visited = loaded.guide_tour.visited_through;
      await check();
      for (let i = 0; i < length; i++) {
        await press(['next', 'next', 'next', 'back', 'back', 'ask', 'ask', 'end', 'overview']);
        await check();
      }
      expect(m.asked, 'the run asked questions').toBeGreaterThan(0);
      expect(pi.userTexts()).toHaveLength(m.deliveredCount);
      console.log(`seed ${seed}: ${length} presses, ${m.asked} questions, ${log.filter((l) => l.startsWith('  revise retried')).length} answer retries, ${m.predicted.size} predictions`);
    } catch (error) {
      await test.info().attach(`presses-seed-${seed}`, { body: log.join('\n'), contentType: 'text/plain' });
      throw error;
    } finally {
      await pi.stop();
    }
  });
}
