terraform {
  backend "s3" {
    # Values supplied at init time via -backend-config in the GitHub Action.
    # Do not hardcode bucket/key/region here — they are injected as secrets.
  }
}
