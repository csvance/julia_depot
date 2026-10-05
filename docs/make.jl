# The documentation site for julia_depot, published to GitHub Pages by
# .github/workflows/Documenter.yml. This repository is a Bazel module, not a Julia
# package, so there are no modules or docstrings to document: the site is the prose
# in docs/src, rendered with MaterialDocs' Material3 writer and a DocumenterLandingPage
# home page. DocumenterCodeBlocks is left out on purpose: its value is Julia highlighting
# and docstring links, and the code here is Starlark and shell.
using Documenter
using DocumenterLandingPage
using MaterialDocs

# The version this build documents, from the module itself, so a versioned deploy never
# claims another one. release_prep.sh refuses a tag that disagrees with it.
const MODULE_VERSION = match(
    r"^\s*version\s*=\s*\"([^\"]+)\""m,
    read(joinpath(@__DIR__, "..", "MODULE.bazel"), String),
)[1]

makedocs(
    sitename = "julia_depot",
    doctest = false,
    format = Material3(
        edit_link = "main",
        canonical = "https://csvance.github.io/julia_depot/",
        inventory_version = MODULE_VERSION,
    ),
    repo = Documenter.Remotes.GitHub("csvance", "julia_depot"),
    plugins = [
        LandingPage(),
    ],
    pages = [
        "Home" => "index.md",
        "Images" => "images.md",
        "Recipes" => "recipes.md",
        "The contract" => "contract.md",
        "Julia versions" => "julia-versions.md",
        "Testing" => "testing.md",
    ],
)

Documenter.deploydocs(
    repo = "github.com/csvance/julia_depot.git",
    push_preview = true,
    devbranch = "main",
)
