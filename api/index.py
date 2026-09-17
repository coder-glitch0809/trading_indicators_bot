"""Vercel entrypoint for the Flask application."""
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = PROJECT_ROOT / "server"
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from server import app  # noqa: E402,F401
