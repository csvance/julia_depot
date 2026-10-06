# Used by

Projects that build with `julia_depot`, and what they use it for.

| Project | How it uses `julia_depot` |
| --- | --- |
| [ReactantServer.jl](https://github.com/EnzymeAD/ReactantServer.jl) | Builds its inference-server node image, published to GHCR with signed build provenance. `julia.dist` pins the Julia; `julia_image_env` declares the image's layout, with the workspace root as an extra depot so the application's own packages get relocatable caches; `julia_dist_layer`, `julia_depot_layer` (`contents = "full"`, since the image loads packages from source) and `julia_compiled_layer` produce the Julia layers; and `julia_precompile_test` checks the image starts without precompiling. The image is assembled with `rules_oci` on a CUDA base. See its [`deploy/`](https://github.com/EnzymeAD/ReactantServer.jl/tree/main/deploy) package. |

Using `julia_depot` in a public project? Open a pull request adding a row.
