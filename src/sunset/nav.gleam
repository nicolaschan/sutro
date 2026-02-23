@external(javascript, "./nav.ffi.mjs", "set_hash")
pub fn set_hash(_hash: String) -> Nil {
  Nil
}

@external(javascript, "./nav.ffi.mjs", "get_hash")
pub fn get_hash() -> String {
  ""
}

@external(javascript, "./nav.ffi.mjs", "clear_hash")
pub fn clear_hash() -> Nil {
  Nil
}

@external(javascript, "./nav.ffi.mjs", "on_hash_change")
pub fn on_hash_change(_callback: fn(String) -> Nil) -> Nil {
  Nil
}
