"""
Python distribution cleaner that attempts to prune unnecessary
modules by running dependency analysis/verification against a given python module.
See umu-cleaner-config.py for an example of specifying extra module-specific options.
"""

import argparse
import ast
import logging
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Set, Tuple

@dataclass
class CleanerConfig:
    """Configuration settings for the Python distribution cleaner."""

    # Core Python modules/directories to not remove
    essential_dirs: Set[str] = field(default_factory=lambda: {
        'lib-dynload',      # Dynamic loading support
        'encodings',        # Text encoding support
        'importlib',        # Import machinery
    })

    # Common build dependencies
    build_dependencies: Set[str] = field(default_factory=lambda: {
        'setuptools', 'pip'
    })

    # Standard test/build artifacts to ignore during the import analysis
    ignore_modules: Set[str] = field(default_factory=lambda: {
        'test',
        'mock',
        'pytest',
    })

    # Basic removable patterns
    removable_dirs: Set[str] = field(default_factory=lambda: {
        '__pycache__',
        'test', 'tests',
        'site-packages',
    })

    removable_files: Set[str] = field(default_factory=lambda: {
        '*.pyc', '*.pyo',   # Bytecode
        '*.html', '*.txt',  # Documentation
        'LICENSE*', 'README*', 'CHANGES*', 'NEWS*',
    })

    # Project-specific configurations
    optional_dependencies: Set[str] = field(default_factory=set)
    project_specific_ignores: Set[str] = field(default_factory=set)
    removable_modules: Set[str] = field(default_factory=set)

    @classmethod
    def from_file(cls, config_path: Path) -> 'CleanerConfig':
        """Load configuration from a Python file."""
        config_dict = {}
        if config_path.exists():
            with open(config_path) as f:
                exec(f.read(), {}, config_dict)

        config = cls()

        # Update with file-provided values, extending sets rather than replacing
        for key, value in config_dict.items():
            if hasattr(config, key):
                if isinstance(value, set):
                    # Extend existing sets rather than replace
                    getattr(config, key).update(value)
                else:
                    setattr(config, key, value)

        return config

class ImportAnalyzer(ast.NodeVisitor):
    """AST visitor that collects and categorizes import statements."""

    def __init__(self, config: CleanerConfig):
        self.config = config
        self.runtime_imports: Set[str] = set()
        self.build_imports: Set[str] = set()
        self.optional_imports: Set[str] = set()

    def visit_Import(self, node: ast.Import) -> None:
        """Process 'import foo' statements."""
        for name in node.names:
            base_module = name.name.split('.')[0]
            if not self._should_ignore(base_module):
                self._categorize_import(base_module)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        """Process 'from foo import bar' statements."""
        if node.module:
            base_module = node.module.split('.')[0]
            if not self._should_ignore(base_module):
                self._categorize_import(base_module)

    def _should_ignore(self, module: str) -> bool:
        """Check if a module should be ignored during analysis."""
        return module in self.config.ignore_modules or module in self.config.project_specific_ignores

    def _categorize_import(self, module: str) -> None:
        """Categorize an import based on its dependency type."""
        if module in self.config.build_dependencies:
            self.build_imports.add(module)
        elif module in self.config.optional_dependencies:
            self.optional_imports.add(module)
        else:
            self.runtime_imports.add(module)

class PythonDistributionManager:
    """Manages Python distribution analysis and cleaning."""

    def __init__(self, dist_path: Path, source_dir: Path, config: CleanerConfig,
                 debug: bool = False):
        self.dist_path = dist_path
        self.source_dir = source_dir
        self.config = config
        self.debug = debug
        self.logger = self._setup_logger()

    def _setup_logger(self) -> logging.Logger:
        level = logging.DEBUG if self.debug else logging.INFO
        logging.basicConfig(level=level, format='%(message)s')
        return logging.getLogger(__name__)

    def _get_lib_path(self) -> Path:
        """Find the Python library directory."""
        for path in self.dist_path.glob('lib/python3.*'):
            if path.is_dir():
                return path
        raise RuntimeError("Could not find Python library directory")

    def analyze_imports(self) -> Tuple[Set[str], Dict[str, int]]:
        """Analyze imports in the source directory."""
        runtime_imports = set()
        file_stats = {'total': 0, 'analyzed': 0, 'errors': 0}

        for path in self.source_dir.rglob('*.py'):
            file_stats['total'] += 1
            try:
                with open(path) as f:
                    tree = ast.parse(f.read(), str(path))
                analyzer = ImportAnalyzer(self.config)
                analyzer.visit(tree)
                runtime_imports.update(analyzer.runtime_imports)
                file_stats['analyzed'] += 1
            except (SyntaxError, FileNotFoundError) as e:
                self.logger.warning(f"Warning: analyzing {path} raised {e}")
                file_stats['errors'] += 1

        return runtime_imports, file_stats

    def clean_distribution(self) -> Dict[str, int]:
        """Clean the Python distribution while preserving required modules."""
        stats = {'removed': 0, 'initial_size': 0, 'final_size': 0}

        stats['initial_size'] = sum(f.stat().st_size for f in self.dist_path.rglob('*') if f.is_file())

        # Get required modules
        required_modules, analysis_stats = self.analyze_imports()
        self.logger.debug(f"Found {len(required_modules)} required modules")
        self.logger.debug(f"Analysis stats: {analysis_stats}")

        # First clean Python-specific directories
        python_lib = self._get_lib_path()
        for path in python_lib.rglob('*'):
            if any(parent.name in self.config.essential_dirs for parent in path.parents):
                continue

            if path.is_file():
                if (path.name in self.config.removable_modules or
                    any(path.match(pattern) for pattern in self.config.removable_files)):
                    path.unlink()
                    stats['removed'] += 1

            elif path.is_dir():
                if any(path.match(pattern) for pattern in self.config.removable_dirs):
                    shutil.rmtree(path, ignore_errors=True)
                    stats['removed'] += 1

        # Then clean the main lib directory for Tcl/Tk and other non-Python files
        lib_dir = self.dist_path / 'lib'
        if lib_dir.exists():
            for path in lib_dir.iterdir():
                # Skip the Python directory as we already cleaned it
                if path == python_lib:
                    continue

                if path.is_dir():
                    if any(path.match(pattern) for pattern in self.config.removable_dirs):
                        shutil.rmtree(path)
                        stats['removed'] += 1
                elif path.is_file():
                    if any(path.match(pattern) for pattern in self.config.removable_files):
                        path.unlink()
                        stats['removed'] += 1

        # Clean empty directories
        for path in sorted(self.dist_path.rglob('*'), reverse=True):
            if path.is_dir() and not any(path.iterdir()):
                try:
                    path.rmdir()
                    stats['removed'] += 1
                except OSError:
                    pass

        stats['final_size'] = sum(f.stat().st_size for f in self.dist_path.rglob('*') if f.is_file())

        return stats

def main():
    parser = argparse.ArgumentParser(
        description='Analyze and clean Python distribution for specific applications'
    )
    parser.add_argument('dist_path', type=Path,
                      help='Path to Python distribution directory')
    parser.add_argument('source_dir', type=Path,
                      help='Path to source directory to analyze')
    parser.add_argument('--config', type=Path,
                      help='Path to configuration file')
    parser.add_argument('--imports-only', action='store_true',
                      help='Only analyze and output required imports')
    parser.add_argument('--debug', action='store_true',
                      help='Enable debug logging')
    parser.add_argument('--project-ignores', type=str, nargs='*',
                      help='Additional project-specific modules to ignore')

    args = parser.parse_args()

    if not args.dist_path.exists():
        sys.exit(f"Distribution path not found: {args.dist_path}")
    if not args.source_dir.exists():
        sys.exit(f"Source directory not found: {args.source_dir}")

    config = (CleanerConfig.from_file(args.config)
             if args.config and args.config.exists()
             else CleanerConfig())

    if args.project_ignores:
        config.project_specific_ignores.update(args.project_ignores)

    manager = PythonDistributionManager(args.dist_path, args.source_dir, config, args.debug)

    if args.imports_only:
        imports, stats = manager.analyze_imports()
        print(','.join(sorted(imports)))
        sys.exit(0)

    stats = manager.clean_distribution()

    size_saved = (stats['initial_size'] - stats['final_size']) / 1024 / 1024
    final_size = stats['final_size'] / 1024 / 1024

    manager.logger.info(f"Files and directories removed: {stats['removed']}")
    manager.logger.info(f"Space saved: {size_saved:.1f}MB")
    manager.logger.info(f"Final distribution size: {final_size:.1f}MB")

if __name__ == '__main__':
    main()
