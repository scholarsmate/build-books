# Design: Plugin-based CLI Dynamic Dispatch with Click

## Why this pattern

As CLIs grow, a static `main.py` that hard-codes subcommands becomes a merge-conflict factory and a long-term maintenance risk. A plugin-based architecture solves this by letting teams add new verbs by **adding a file** rather than editing shared CLI wiring.

This design uses **Click** for parsing/help/UX and a **central dispatch registry** for scalable, low-boilerplate plugin authoring.

---

## Core principles

* **Stable entry point**: the CLI front door stays boring.
* **Plugins own registration**: a command registers itself via a decorator.
* **Single source of truth**: handler function signatures define CLI options.
* **Keyword-only parameters**: after the shared `results` object, all args are keyword-only.
* **Deterministic behavior**: stable ordering, explicit conflicts, predictable help text.
* **Failure isolation**: bad plugins don’t brick the whole CLI.

---

## The contract

A plugin handler is a standalone function:

```python
def ingest(results: ResultObject, *, data_type: DataType, data_file: IO[str]) -> None:
    """Ingest a data file into the system."""
    ...
```

Rules:

* First parameter is always `results`.
* All remaining parameters are **keyword-only**.
* Use **Enums for finite string domains** (e.g., `DataType`, `Format`, `Mode`).
* The first docstring line becomes the command summary (help text).

---

## Directory layout

```text
mytool/
  src/mytool/
    cli.py                 # stable entry point
    core/
      dispatch.py          # DISPATCH + decorator + metadata
      plugins.py           # discovery + safe import
      click_factory.py     # signature -> Click commands
      results.py           # ResultObject
    plugins/
      ingest.py
      check.py
      report.py
```

Adding a new verb is “drop a new module in `plugins/`”.

---

## Best practices

* **One verb per module** (reduces conflicts and keeps ownership clear).
* **Explicit conflicts**: fail fast if two plugins register the same verb.
* **Deterministic discovery**: stable ordering (sorted module names).
* **Safe imports**: import failures become warnings; command is skipped.
* **Keep `ResultObject` stable**: treat it as an API (add fields deliberately).
* **Finite string values should be Enums**: if a parameter is a small fixed set of strings, model it as an `Enum` (or `Literal[...]` if you must, but prefer `Enum` for reusability and central governance).
* **Types are UX**: use annotations (`int`, `Path`, `Enum`, `IO[str]`) to generate better options.
* **CI plugin validation**: a test that imports all plugins and ensures:

  * signature contract is met
  * no duplicate verbs
  * docs present (optional)

### Documentation that includes parameters

Click will show a command’s **summary** (the first docstring line) automatically, but parameter documentation needs a policy.

Recommended practice:

* Use the first docstring line as the **one-line summary**.
* Use the remaining docstring body as **extended help**.
* For parameters, document them in a consistent block (Google-style, NumPy-style, or a short “Args:” section). Example:

```python
@command()
def ingest(results: ResultObject, *, data_type: DataType, data_file: IO[str]) -> None:
    """Ingest a data file into the system.

    Args:
        data_type: Logical category of the file being ingested.
        data_file: Input file handle (opened by Click).
    """
```

Optional enhancement (when you need it): extend the command decorator/metadata to record per-parameter help strings (e.g., via a small `@param_help({...})` decorator). Keep this out of the “minimal” path until teams actually need richer help than docstrings.

### Result objects: best practice or optional?

A `ResultObject` is not mandatory, but it is a **pragmatic best practice** for dynamic dispatch in multi-command CLIs because it:

* creates a stable place for shared output/state (events, warnings, metrics)
* prevents handlers from printing ad-hoc text everywhere
* makes unit testing easier (assert on `results.events`)
* supports future output modes (text vs JSON) without changing plugins

Rule of thumb:

* If commands are simple one-offs, you can return exit codes directly.
* If you expect growth, multiple outputs, or structured reporting, keep `ResultObject`.

### Return codes and error signaling

In production CLIs, exit codes are part of the API.

Suggested convention:

* `0`: success
* `1`: usage/config/user error (bad input, missing file, invalid option)
* `2`: command failed (domain/environment/plugin failure)
* `70`: internal software error (BSD `EX_SOFTWARE`) — reserved for bugs/unhandled exceptions
* `130`: interrupted by Ctrl+C (SIGINT)

**Enterprise rule:** plugins must **never** call `SystemExit` or manipulate process exit codes directly.

Implementation guidance:

* Plugins express outcomes via `results` (events + `ok`).
* User-facing input/usage failures should raise `click.ClickException` (or `click.UsageError`) — Click exits with code **1**.
* The wrapper computes the final exit code from `results` and exits accordingly.

### Signal handling (Ctrl+C and friends)

Click already handles Ctrl+C reasonably, but if you want consistent behavior:

* Catch `KeyboardInterrupt` in the callback wrapper and exit `130`.
* For long-running commands, consider cooperative cancellation (set a flag or use `signal.signal(SIGINT, ...)` to request stop).

Avoid doing heavy signal wiring in every plugin. Keep it in the stable entry point or the callback wrapper.

### Error policy (recommended)

Treat errors as part of the CLI API. Keep it consistent across all plugins.

**Policy**

* **User/usage/config errors**: raise `click.ClickException("...")` (or `click.UsageError`) → **exit code 1**.
* **Domain/environment/plugin failures**: record the failure in `results` via `results.fail(...)` → wrapper exits **2**.
* **Bugs/unhandled exceptions**: wrapper catches, records `E_BUG_*`, exits **70**.
* **Ctrl+C / SIGINT**: wrapper exits **130**.

**Enterprise rule:** plugins must not call `SystemExit` (or `os._exit`). Only the wrapper decides process termination.

### Error code catalog (recommended)

In addition to process exit codes, use **stable error codes** inside events so automation can reason about failures without scraping text.

**Conventions**

* Codes are **UPPER_SNAKE_CASE**.
* Codes are stable once published.
* Use **numeric codes** for easy aggregation/alerting, and keep the Enum name as the human/machine-readable identifier.

### Enterprise-grade: define codes in one place

Create a dedicated `errors.py` that defines an `IntEnum` catalog. `IntEnum` gives you:

* a stable numeric value (`int(code)`)
* a stable symbolic name (`code.name`)

```python
# core/errors.py
from enum import IntEnum

class ErrorCode(IntEnum):
    # Success
    OK = 0

    # 1xxx: input / usage
    E_INPUT_NOT_FOUND = 1001
    E_INPUT_INVALID = 1002

    # 2xxx: config
    E_CONFIG_MISSING = 2001
    E_CONFIG_INVALID = 2002

    # 3xxx: environment
    E_ENV_PERMISSION = 3001
    E_ENV_IO = 3002

    # 4xxx: plugins
    E_PLUGIN_IMPORT = 4001
    E_PLUGIN_CONFLICT = 4002

    # 5xxx: domain failures
    E_DOMAIN_CONSTRAINT = 5001
    E_DOMAIN_NOT_READY = 5002

    # 9xxx: internal bugs
    E_BUG_UNHANDLED = 9001
    E_BUG_ASSERT = 9002
```

### Mapping to exit codes

* `ErrorCode.OK` → exit **0**
* `E_INPUT_*`, `E_CONFIG_*` → exit **1**
* `E_DOMAIN_*`, `E_ENV_*`, `E_PLUGIN_*` → exit **2**
* `E_BUG_*` → exit **70**

This dual-layer approach (exit code + stable error catalog) gives you:

* human-friendly CLI behavior
* machine-friendly automation
* freedom to add richer diagnostics over time
* standardized logs that include **both** the numeric code and Enum name

### Output policy (recommended)

Plugins should **never print**. They should only add structured events to `ResultObject`.

**Policy**

* Plugins emit events: `results.add_event("kind", ...)`.
* The wrapper renders events.
* Support at least two formats:

  * `--output text` (human-friendly, default)
  * `--output json` (machine-friendly)

This decouples business logic from presentation and lets you add logging/telemetry later without touching plugins.

### Battle-tested tweak: stable event schema

If you intend to support `--output json`, treat your event payloads as a compatibility surface.

Recommended event schema (minimal, extensible):

* `kind`: short event type (e.g., `ingest`, `check`, `error`)
* `message`: human-friendly summary (optional but recommended)
* `code`: stable symbolic identifier (Enum name, e.g., `E_INPUT_INVALID`)
* `code_num`: stable numeric code (e.g., `1002`)
* `ts`: ISO-8601 timestamp (UTC)
* `details`: nested dict for anything command-specific

Guidelines:

* Keep top-level keys stable; put command-specific fields under `details`.
* Prefer adding new keys over renaming existing ones.
* For text output, render `message` + a compact view of `details`.

Example event:

```json
{
  "kind": "error",
  "message": "Input file not found",
  "code": "E_INPUT_NOT_FOUND",
  "code_num": 1001,
  "ts": "2026-01-19T22:10:00Z",
  "details": {"path": "sample.txt"}
}
```

---

---

---

## Worked example (minimal but production-shaped)

### 0) ResultObject and event schema

In practice you’ll want `ResultObject.add_event()` to encourage the stable schema.

```python
# core/results.py
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from .errors import ErrorCode

@dataclass
class ResultObject:
    ok: bool = True
    events: list[dict[str, Any]] = field(default_factory=list)

    def add_event(
        self,
        kind: str,
        *,
        message: str | None = None,
        code: ErrorCode | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.events.append({
            "kind": kind,
            "message": message,
            # include BOTH numeric and symbolic forms
            "code": code.name if code is not None else None,
            "code_num": int(code) if code is not None else None,
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "details": details or {},
        })

    def fail(self, message: str, *, code: ErrorCode, details: dict[str, Any] | None = None) -> None:
        self.ok = False
        self.add_event("error", message=message, code=code, details=details)
```

### 1) Dispatch registry + decorator

```python
# core/dispatch.py
from dataclasses import dataclass
from typing import Any, Callable

Handler = Callable[..., Any]
DISPATCH: dict[str, Handler] = {}

@dataclass(frozen=True)
class CommandMeta:
    verb: str
    summary: str
    module: str

COMMAND_META: dict[str, CommandMeta] = {}

class RegistrationError(RuntimeError):
    pass

def command(verb: str | None = None, *, summary: str | None = None):
    def decorate(fn: Handler) -> Handler:
        v = verb or fn.__name__
        doc = (fn.__doc__ or "").strip()
        s = summary or (doc.splitlines()[0].strip() if doc else "Run command")

        if v in DISPATCH:
            prev = COMMAND_META.get(v)
            raise RegistrationError(
                f"Duplicate verb '{v}' registered by {fn.__module__}; "
                f"already registered by {prev.module if prev else 'unknown'}"
            )

        DISPATCH[v] = fn
        COMMAND_META[v] = CommandMeta(verb=v, summary=s, module=fn.__module__)
        return fn

    return decorate
```

### 2) Plugin discovery (safe import)

```python
# core/plugins.py
import importlib, pkgutil
import click

def load_plugins(package: str) -> None:
    pkg = importlib.import_module(package)
    for m in sorted(pkgutil.iter_modules(pkg.__path__, prefix=f"{package}."), key=lambda x: x.name):
        if m.ispkg:
            continue
        try:
            importlib.import_module(m.name)
        except Exception as e:
            click.echo(f"Warning: plugin import failed: {m.name} ({e!r})", err=True)
```

### 3) Build Click commands dynamically from signatures

Below shows the core idea. For the **output policy**, the root command defines global options (`--output`, `--quiet`) and stores them in `ctx.obj` so every subcommand shares the same renderer.

```python
# core/click_factory.py
import inspect
import json
import click
from typing import Any, Callable, IO, get_origin
from enum import Enum

from .dispatch import DISPATCH, COMMAND_META
from .results import ResultObject


def _flag(name: str) -> str:
    return "--" + name.replace("_", "-")


def _is_io(ann: Any) -> bool:
    origin = get_origin(ann)
    return ann is IO or origin is IO


def _render(results: ResultObject, *, output: str, quiet: bool) -> None:
    if quiet:
        return
    if output == "json":
        click.echo(json.dumps({"ok": results.ok, "events": results.events}, default=str))
        return

    # text (default): message first, then compact details
    for ev in results.events:
        kind = ev.get("kind", "event")
        msg = ev.get("message")
        details = ev.get("details") or {}
        tail = " ".join(f"{k}={v}" for k, v in details.items())
        code = ev.get("code")
        code_num = ev.get("code_num")
        code_part = f" ({code}:{code_num})" if code or code_num is not None else ""
        line = f"[{kind}]" + code_part + (f" {msg}" if msg else "") + (f" {tail}" if tail else "")
        click.echo(line)


def build_cli(prog_name: str = "mytool") -> click.Group:
    @click.group(name=prog_name)
    @click.option("--output", type=click.Choice(["text", "json"], case_sensitive=False), default="text", show_default=True)
    @click.option("--quiet", is_flag=True, default=False)
    @click.pass_context
    def root(ctx: click.Context, output: str, quiet: bool) -> None:
        """Plugin-based CLI with dynamic dispatch."""
        ctx.ensure_object(dict)
        ctx.obj["output"] = output
        ctx.obj["quiet"] = quiet

    for verb, fn in sorted(DISPATCH.items()):
        meta = COMMAND_META.get(verb)
        help_text = meta.summary if meta else None
        sig = inspect.signature(fn)
        params = list(sig.parameters.values())

        # enforce: fn(results, *, ...)
        if not params:
            raise RuntimeError(f"{verb}: missing results parameter")
        if params[0].kind not in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD):
            raise RuntimeError(f"{verb}: first param must be positional 'results'")
        for p in params[1:]:
            if p.kind is not inspect.Parameter.KEYWORD_ONLY:
                raise RuntimeError(f"{verb}: params after results must be keyword-only")

        def make_callback(fn: Callable[..., Any], sig: inspect.Signature, verb: str):
            def callback(**kwargs: Any) -> None:
                ctx = click.get_current_context()
                output = (ctx.obj or {}).get("output", "text")
                quiet = (ctx.obj or {}).get("quiet", False)

                results = ResultObject()
                bug = False

                try:
                    bound = sig.bind_partial(results, **kwargs)  # validates keyword binding
                    fn(*bound.args, **bound.kwargs)
                except click.ClickException:
                    # user/usage/config error -> click exits 1
                    raise
                except KeyboardInterrupt:
                    raise SystemExit(130)
                except Exception as e:
                    # bug/unhandled -> normalize into results, but wrapper owns exit code
                    from .errors import ErrorCode
                    bug = True
                    results.fail("Unhandled exception", code=ErrorCode.E_BUG_UNHANDLED, details={"exception": repr(e)})

                _render(results, output=output, quiet=quiet)

                # Wrapper decides exit code; plugins never call SystemExit.
                if bug:
                    raise SystemExit(70)
                if results.ok:
                    raise SystemExit(0)

                # Determine exit code from numeric ErrorCode ranges.
                # 0: OK
                # 1xxx-2xxx: input/config -> 1
                # 3xxx-5xxx: env/plugin/domain -> 2
                # 9xxx: bugs -> 70 (handled above)
                code_nums = [ev.get("code_num") for ev in results.events if ev.get("kind") == "error" and ev.get("code_num") is not None]
                # If plugins failed but did not emit numeric codes, default to 2 for safety.
                if not code_nums:
                    raise SystemExit(2)

                # Any input/config error => 1
                if any(1000 <= n < 3000 for n in code_nums):
                    raise SystemExit(1)

                # Otherwise treat as operational/domain failure => 2
                raise SystemExit(2)

            return callback

        cmd = click.Command(name=verb, callback=make_callback(fn, sig, verb), help=help_text)

        # build options from keyword-only params
        for p in reversed(params[1:]):
            ann = p.annotation if p.annotation is not inspect._empty else str
            has_default = p.default is not inspect._empty
            default = None if not has_default else p.default

            if ann is bool:
                # mature bool UX: default False -> --flag, default True -> --no-flag
                if has_default and default is True:
                    opt = click.Option([f"--no-{p.name.replace('_','-')}"] , is_flag=True, default=False)
                else:
                    opt = click.Option([_flag(p.name)], is_flag=True, default=False)
                cmd.params.insert(0, opt)
                continue

            if _is_io(ann):
                opt = click.Option([_flag(p.name)], type=click.File("r"), required=not has_default, default=default, metavar="PATH")
                cmd.params.insert(0, opt)
                continue

            # improved mapping: Enum -> Choice; otherwise primitives
            if isinstance(ann, type) and issubclass(ann, Enum):
                choices = [m.value for m in ann]  # values are user-facing
                opt = click.Option([_flag(p.name)], type=click.Choice(choices, case_sensitive=False), required=not has_default, default=(default.value if default else None), show_default=has_default)
                cmd.params.insert(0, opt)
                continue

            ctype = click.INT if ann is int else click.FLOAT if ann is float else click.STRING
            opt = click.Option([_flag(p.name)], type=ctype, required=not has_default, default=default, show_default=has_default)
            cmd.params.insert(0, opt)

        root.add_command(cmd)

    return root
```

### 4) Stable CLI entry point

```python
# cli.py
import sys
from mytool.core.plugins import load_plugins
from mytool.core.click_factory import build_cli


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    load_plugins("mytool.plugins")
    cli = build_cli("mytool")
    cli.main(args=argv, prog_name="mytool", standalone_mode=True)
    return 0
```

### 5) Example plugin

```python
# plugins/ingest.py
from enum import Enum
from typing import IO

from mytool.core.dispatch import command
from mytool.core.results import ResultObject
from mytool.core.errors import ErrorCode

class DataType(str, Enum):
    USERS = "users"
    ORDERS = "orders"
    EVENTS = "events"

@command()
def ingest(results: ResultObject, *, data_type: DataType, data_file: IO[str]) -> None:
    """Ingest a data file into the system.

    Args:
        data_type: Logical category of the file being ingested.
        data_file: Input file handle (opened by Click).
    """
    text = data_file.read()
    results.add_event(
        "ingest",
        message="Ingest completed",
        code=ErrorCode.OK,
        details={"data_type": data_type.value, "bytes": len(text.encode("utf-8"))},
    )
```

---

## Note: can Click do dispatch by itself?

Click **already dispatches** to the correct callback once commands exist (group → subcommand routing).

What Click does **not** provide out of the box is **automatic command generation from arbitrary function signatures** and **plugin discovery**. That’s the thin layer this pattern adds.

This design intentionally keeps plugin authoring light (plain functions + `@command`) while Click handles parsing, help text, option validation, and CLI ergonomics.

---

## Operational checklist (recommended)

* Add a CI test that imports all plugins and asserts:

  * no duplicate verbs
  * all handler signatures match the contract
* Add `--debug-plugins` to print loaded/skipped plugins
* Consider optional third-party plugins via entry points when the ecosystem grows
