def make_exe():
    dist = default_python_distribution()
    policy = dist.make_python_packaging_policy()
    policy.allow_files = True
    policy.resources_location = "in-memory"
    policy.include_distribution_sources = True
    policy.include_distribution_resources = True
    policy.include_non_distribution_sources = True
    policy.include_test = False

    python_config = dist.make_python_interpreter_config()

    # PyOxidizer workarounds for __file__ not being set and sys.argv[0] not being set
    python_config.run_command = """
import sys
import os
import builtins

executable_path = os.path.abspath(sys.executable)

# Keep the original argv[0]
if len(sys.argv) > 0:
    sys.argv[0] = os.path.basename(sys.argv[0])
else:
    sys.argv.insert(0, os.path.basename(executable_path))

builtins.__file__ = executable_path
sys.path.insert(0, os.path.dirname(executable_path))

from umu.__main__ import main
sys.exit(main())
"""

    python_config.sys_frozen = True

    exe = dist.to_python_executable(
        name="umu-run-pyoxidizer",
        packaging_policy=policy,
        config=python_config,
    )

    exe.add_python_resources(exe.read_package_root(
        path="../",
        packages=["umu"],
    ))

    exe.add_python_resources(exe.pip_install(["-r", "../requirements.in"]))
    exe.add_python_resources(exe.pip_install(["importlib-metadata"]))

    exe.windows_runtime_dlls_mode = "never"

    return exe

def make_embedded_resources(exe):
    return exe.to_embedded_resources()

def make_install(exe):
    files = FileManifest()

    # Add the generated executable to our install layout in the root directory.
    files.add_python_resource(".", exe)

    # Add umu_version.json to the install layout
    umu_version_content = FileContent(
        path="../umu/umu_version.json",
        filename="umu_version.json"
    )
    files.add_file(umu_version_content, path="umu_version.json")

    # # Add the prctl helper to the install layout, so we don't rely on CDLL dynamic loading in umu-launcher
    # umu_run_wrapper_content = FileContent(
    #     path="./umu-run",
    #     filename="umu-run"
    # )
    # files.add_file(umu_run_wrapper_content, path="umu-run")

    return files

register_target("exe", make_exe)
register_target("resources", make_embedded_resources, depends=["exe"], default_build_script=True)
register_target("install", make_install, depends=["exe"], default=True)

resolve_targets()