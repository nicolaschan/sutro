# sunset

Peer-to-peer chat built with [Gleam](https://gleam.run/) + [Lustre](https://lustre.build/) and [libp2p](https://libp2p.io/).

## Development

Requires [Nix](https://nixos.org/) with flakes enabled.

```sh
nix run          # Start the Lustre dev server
gleam test       # Run the tests
```

## Deployment

Deployed to GitHub Pages via CI on push to `main`/`master`.
