"""Analysis tests: which compiler julia_sysimage_layer hands sysimage.sh, and what that does to its action.

A sysimage build takes minutes, so the wiring is checked at analysis time instead: the
JULIA_DEPOT_SYSIMAGE_CC the action is given, and whether the compiler is among its inputs, which
is what puts it in the action key. The builds themselves are covered by sysimage_link_<minor>_test
and the sysimage.sh tests. Starlark cannot read an action's execution requirements, so the
no-remote-cache tag on a system_cc build is not checked here.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _sysimage_action(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "JuliaSysimageLayer"]
    asserts.equals(env, 1, len(actions), "JuliaSysimageLayer actions")
    return actions[0] if actions else None

def _input_paths(action):
    return [f.path for f in action.inputs.to_list()]

def _pinned_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _sysimage_action(env)
    if action:
        cc = action.env.get("JULIA_DEPOT_SYSIMAGE_CC", "")
        want = "+{}/bin/cc".format(ctx.attr.repo)
        asserts.true(env, cc.endswith(want), "JULIA_DEPOT_SYSIMAGE_CC is {}, not the bin/cc of {}".format(cc, ctx.attr.repo))
        inputs = _input_paths(action)
        asserts.true(env, cc in inputs, "the compiler {} is not among the action's inputs".format(cc))
        zig = cc[:-len("bin/cc")] + "zig/zig"
        asserts.true(env, zig in inputs, "zig ({}) is not among the action's inputs".format(zig))
    return analysistest.end(env)

pinned_cc_test = analysistest.make(
    _pinned_test_impl,
    attrs = {"repo": attr.string(doc = "The canonical-name suffix of the julia.cc repository expected, e.g. julia_depot_cc.")},
)

def _system_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _sysimage_action(env)
    if action:
        asserts.equals(env, "system", action.env.get("JULIA_DEPOT_SYSIMAGE_CC"))
        stray = [p for p in _input_paths(action) if p.endswith("/bin/cc")]
        asserts.equals(env, [], stray, "compilers among the inputs of a system_cc build")
    return analysistest.end(env)

system_cc_test = analysistest.make(_system_test_impl)
