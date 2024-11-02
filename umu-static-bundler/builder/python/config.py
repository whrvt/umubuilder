"""
umu-specific configuration for python-cleaner.py
"""

project_specific_ignores = {
    'protocol',  # Internal to package
    'umu',       # The package itself
    'ext',       # Internal extension module
    'xobject',   # Internal to Xlib
}

essential_dirs = {
    'json',
    'collections',
    'logging',
    'urllib',
    'http',
    'email',        # Used by urllib
}

build_dependencies = {
    'wheel',
    'build',
}

optional_dependencies = {
    'readline',
    'curses',
    'sqlite3'
}

removable_dirs = {
    'tkinter', 'turtledemo',
    'idle_test', 'idlelib',
    'lib2to3', 'unittest',
    'pydoc_data', 'ensurepip',
    'config-*',     # Build configuration
    'pkgconfig',
    'include',      # Header files
    '*tcl*',         # Tcl/Tk related
    'tk*',          # Tk GUI toolkit
    'Tix*',         # Tix widget toolkit
    'thread*',      # Thread extension for Tcl
}

removable_files = {
    '*.pyd', '*.pod',         # Additional bytecode formats
    '*.rst',                  # Additional documentation
    '*.mo', '*.pot', '*.po',  # Translations
    '*.h', '*.a', '*.pc',     # Build files
    '*.enc',                  # Character encodings
    '*.ppm',                  # Images
    '*.tcl', '*.tm',          # Tcl/Tk
    'Makefile'                # Build files
}

removable_modules = {
    'turtle.py',
    'pydoc.py',
    'pickletools.py',
    '_pydecimal.py',
    'doctest.py',
    'mock.py',
}
