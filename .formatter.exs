# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # The `._*` sidecar files macOS leaves on a non-native filesystem match the
  # inputs above and are not source. They are ignored by git for the same reason.
  excludes: ["**/._*"]
]
