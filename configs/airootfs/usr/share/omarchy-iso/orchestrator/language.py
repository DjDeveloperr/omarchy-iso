"""The language picked at install, handed to the installed system.

The configurator records the Omarchy language code (a key of
default/i18n/locales.json, such as "da" or "pt-BR") in
omarchy_install.language. The installed system reads it back from
/etc/omarchy/language: the user setup applies it to the installing user, and
the first-boot owner setup preselects it. The glibc locale itself travels
separately, as archinstall's locale_config.sys_lang.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT_LANGUAGE = "en"


def registry_path() -> Path:
    omarchy_path = os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy"
    return Path(omarchy_path) / "default/i18n/locales.json"


def validate_language(language: str | None, registry: Path | None = None) -> str:
    """Return the language code to install, defaulting to English.

    Autoinstall configs written before the language step carry no language at
    all, so absent means English. Anything else must name a language the
    registry knows: the code becomes a path component and a config value on
    the target, and an unknown one would leave the installed system in a
    language nothing can display.
    """
    if language is None or language == "":
        return DEFAULT_LANGUAGE
    if not isinstance(language, str):
        raise ValueError(f"Unknown language: {language!r}")

    registry = registry or registry_path()
    try:
        known = json.loads(registry.read_text())
    except (OSError, ValueError):
        # A runtime without the registry can only speak English.
        known = {DEFAULT_LANGUAGE: {}}

    if language not in known:
        raise ValueError(f"Unknown language: {language}")
    return language


def configure_language(target: Path, language: str) -> None:
    """Write the language code where the installed system looks for it."""
    path = target / "etc/omarchy/language"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{language}\n")
