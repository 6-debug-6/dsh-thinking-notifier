# Contributing

Thanks for considering a contribution to `dsh-thinking-notifier`!

## Development setup

```sh
# Clone the repository
git clone https://github.com/YOUR_GITHUB_USERNAME/dsh-thinking-notifier.git
cd dsh-thinking-notifier

# Install into a local DSH web profile
dsh plugin --profile web add .

# Run DSH web
dsh web
```

The plugin is plain JavaScript and needs no build step.

- Host half: `lib/index.js`
- Windows popup: `desktop-popup.ps1`
- macOS/Linux popup: `desktop-popup.py`

## Testing

```sh
node --check lib/index.js
python -m py_compile desktop-popup.py
```

For Windows popup syntax checking:

```powershell
powershell -NoProfile -Command "& { $t = Get-Content -Raw 'desktop-popup.ps1'; $null = [scriptblock]::Create($t); Write-Output 'parse ok' }"
```

## Debug logs

- `~/.dsh/tn-plugin.log`
- `~/.dsh/tn-launcher.log`
- `~/.dsh/tn-popup-debug.log`

## License

By contributing you agree that your contributions will be licensed under the MIT License.
