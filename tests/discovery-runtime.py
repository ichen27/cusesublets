"""Compatibility entry point for the profile housing-search runtime suite."""
import pathlib, runpy
runpy.run_path(str(pathlib.Path(__file__).with_name("housing-search-runtime.py")), run_name="__main__")
