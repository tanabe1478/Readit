///|
/// A `file://` URI for an absolute path, percent-encoding UTF-8 bytes.
pub fn path_to_uri(path : String) -> String {
  let out = StringBuilder()
  out.write_string("file://")
  for b in @utf8.encode(path) {
    let c = b.to_int()
    let keep = (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
      (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
      (c >= '0'.to_int() && c <= '9'.to_int()) ||
      c == '/'.to_int() ||
      c == '-'.to_int() ||
      c == '.'.to_int() ||
      c == '_'.to_int() ||
      c == '~'.to_int()
    if keep {
      out.write_char(Int::unsafe_to_char(c))
    } else {
      out.write_char('%')
      out.write_char(hex_digit(c / 16))
      out.write_char(hex_digit(c % 16))
    }
  }
  out.to_string()
}

///|
fn hex_digit(n : Int) -> Char {
  "0123456789ABCDEF".get_char(n).unwrap_or('0')
}

///|
fn hex_value(c : Int) -> Int? {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    Some(c - '0'.to_int())
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    Some(c - 'a'.to_int() + 10)
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    Some(c - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// The local path of a `file://` URI; None for other schemes or hosts.
pub fn uri_to_path(uri : String) -> String? {
  let prefix = "file://"
  if !@core.starts_with(uri, prefix) {
    return None
  }
  let mut rest = @core.slice(uri, prefix.length(), uri.length())
  if @core.starts_with(rest, "localhost/") {
    rest = @core.slice(rest, "localhost".length(), rest.length())
  }
  if !@core.starts_with(rest, "/") {
    return None
  }
  let bytes : Array[Byte] = []
  let raw = @utf8.encode(rest)
  let mut i = 0
  while i < raw.length() {
    let c = raw[i].to_int()
    if c == '%'.to_int() && i + 2 < raw.length() {
      match (hex_value(raw[i + 1].to_int()), hex_value(raw[i + 2].to_int())) {
        (Some(h), Some(l)) => {
          bytes.push((h * 16 + l).to_byte())
          i += 3
          continue
        }
        _ => ()
      }
    }
    if c == '?'.to_int() || c == '#'.to_int() {
      break
    }
    bytes.push(raw[i])
    i += 1
  }
  try @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => None
  } noraise {
    s => Some(s)
  }
}

///|
/// Accumulates LSP output decoded as Latin-1, so each character is one byte,
/// and yields complete message bodies still in that byte form.
pub struct Framer {
  mut buffer : String
}

///|
pub fn Framer::new() -> Framer {
  { buffer: "", }
}

///|
/// Largest body accepted from a language server.
pub let max_message : Int = 16 * 1024 * 1024

///|
/// Feed bytes; returns complete bodies. Raises on an invalid frame.
pub fn Framer::feed(
  self : Framer,
  chunk : String,
) -> Array[String] raise Failure {
  self.buffer = self.buffer + chunk
  let out = []
  while true {
    let header_end = @core.find_from(self.buffer, "\r\n\r\n", 0)
    if header_end < 0 {
      if self.buffer.length() > 8192 {
        fail("LSPヘッダーが大きすぎます")
      }
      break
    }
    let mut length = -1
    for line in @core.slice(self.buffer, 0, header_end).split("\r\n") {
      let header = line.to_owned()
      let colon = @core.find_from(header, ":", 0)
      if colon < 0 {
        continue
      }
      let key = @core.lower(@core.trim(@core.slice(header, 0, colon)))
      if key == "content-length" {
        length = @core.parse_natural(
          @core.trim(@core.slice(header, colon + 1, header.length())),
        ).unwrap_or(-1)
      }
    }
    if length < 0 || length > max_message {
      fail("不正なLSPメッセージ長です")
    }
    let body_start = header_end + 4
    if self.buffer.length() < body_start + length {
      break
    }
    out.push(@core.slice(self.buffer, body_start, body_start + length))
    self.buffer = @core.slice(
      self.buffer,
      body_start + length,
      self.buffer.length(),
    )
  }
  out
}
