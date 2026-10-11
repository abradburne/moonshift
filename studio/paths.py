"""Where things live.

CODE holds this package and the setup scripts. HOME holds everything that is
installed or created: models, environments, the music engine, and covers. A
checkout uses one folder for both; the packaged app keeps its code inside the
app bundle and sets MOONSHIFT_HOME to a folder it can write to.
"""
import os
from pathlib import Path

CODE = Path(__file__).resolve().parent.parent
# Resolved, so paths built from it compare equal however the folder was reached.
HOME = Path(os.environ.get("MOONSHIFT_HOME") or CODE).resolve()
