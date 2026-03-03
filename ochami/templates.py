from __future__ import annotations

from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


class TemplateRenderer:
    def __init__(self, template_root: Path) -> None:
        self.template_root = template_root
        self._env = Environment(
            loader=FileSystemLoader(str(template_root)),
            autoescape=False,
            trim_blocks=False,
            lstrip_blocks=False,
            undefined=StrictUndefined,
        )

    def render(self, template_name: str, context: dict[str, object]) -> str:
        template = self._env.get_template(template_name)
        return template.render(**context)

    def render_to_file(self, template_name: str, destination: Path, context: dict[str, object]) -> None:
        destination.write_text(self.render(template_name, context), encoding="utf-8")
