# macupdate

One command that updates and maintains a macOS developer machine: system updates, Mac App Store,
Homebrew, language toolchains (Node, Python, Rust, Ruby, Go and more), editors, optional cleanup,
and a health report. A single Bash script with a real `--dry-run`, per-module status, JSON output
and conservative defaults. Messages and the rest of this README are in Turkish.

## Ne yapar

Tek bir Bash betiği. Modüller gruplara ayrılır; varsayılan çalıştırma yalnız `core` grubunu koşar.

| Grup | Modüller | Nasıl açılır |
|---|---|---|
| `doctor` | kurulum, izin ve sağlık kontrolleri | `--doctor` |
| `core` | softwareupdate, mas, brew, node, python, rust, ruby, go, docker, cache, brew-services | varsayılan |
| `extended` | deno, flutter, haskell, composer, asdf, mise, swift, gcloud, aws, az, heroku, dotnet, pyenv, krew, helm | `--extended` |
| `editors` | vscode, vscode-insiders, cursor, windsurf, neovim, tmux, omz, fzf | `--editors` |
| `deep-clean` | browser-cache, app-cache, mail-downloads, ios-backups, system-logs | `--deep-clean` (onay ister) |
| `ollama` | ollama | `--ollama-update` |
| `repos` | depolarda `fetch` ve yalnız fast-forward | `--repos [yol]` |
| `audit` | audit-unmanaged, audit-broken-casks, audit-duplicates, audit-orphans | `--audit` |
| `inventory` | inventory | `--inventory [yol]` |

Kurulu olmayan araçların modülleri atlanır.

## Kurulum

Gereken: macOS ve Bash 4.3 ya da üstü (`brew install bash`; betik sistemdeki 3.2 ile başlatılırsa
Homebrew Bash'iyle kendini yeniden başlatır).

```bash
install -m 755 macupdate /usr/local/bin/macupdate   # ya da PATH'teki başka bir dizin
macupdate --init-config                              # ~/.config/macupdate/config.sh
```

## Kullanım

```bash
macupdate                      # güvenli çekirdek güncellemeler
macupdate --report             # güncelleme yapmadan rapor
macupdate --dry-run            # yapılacak komutları gösterir, hiçbirini çalıştırmaz
macupdate --only brew,node     # seçili modüller
macupdate --list-modules
macupdate --all                # extended + editors + maintenance (deep-clean dahil değil)
macupdate --json               # insan özeti + JSON dosyası
```

Bütün seçenekler betiğin başındaki açıklamada. Log ve JSON `~/.cache/macupdate/` altına yazılır.

Çıkış kodları: `0` tamam, `1` en az bir modül hata verdi, `2` en az bir modül kısmi kaldı ya da yeniden
başlatma gerekiyor, `64` kullanım hatası, `69` macOS değil, `75` başka bir macupdate çalışıyor.

## Güvenlik ilkeleri

- `--dry-run` değiştiren hiçbir komutu çalıştırmaz; yalnız salt okunur sorgular koşar. Yazdığı tek şey kendi
  çalıştırma kayıtlarıdır: `~/.cache/macupdate/` altında o koşunun günlüğü, `latest.log` bağlantısı ve koşu
  bitince kaldırılan kilit. Eski günlükler dry-run'da silinmez.
- Varsayılan çalıştırma cache silmez; bunlar `--maintenance` ya da `--aggressive-clean` ister.
- `deep-clean` silmeden önce onay ister; terminal yoksa `--yes` olmadan silmez.
- conda'ya dokunulmaz; `sudo gem` ve `chown` yapılmaz.
- `--repos` yalnız `git merge --ff-only` yapar; değişikliği olan, uzak dalı olmayan ya da ayrışmış depoya dokunmaz.

## Kendi kurulumuna uyarlama

Ayarlar `~/.config/macupdate/config.sh` içinde durur (`macupdate --init-config` örnek dosyayı yazar):

- `GREEDY_EXCLUDE`: `--greedy` ile bile güncellenmeyecek cask'lar. Varsayılan boştur; kendi listeni eklemek için
  `GREEDY_EXCLUDE+=(zoom slack)` gibi bir satır yaz.
- `MAS_SKIP_IDS`: atlanacak Mac App Store uygulama kimlikleri, örneğin `MAS_SKIP_IDS+=(1569813296)`.
- `REPOS_DIR` ve `REPOS_BUCKETS`: `--repos` hangi depolara bakar. Varsayılan yazarın dizin düzenidir:
  `~/projects` altındaki `public`, `private` ve `clones` dizinlerinin doğrudan alt depoları. Kök dizinde bu adlarda
  alt dizin yoksa kökün doğrudan alt depolarına bakılır; kök `--repos <yol>` ile de verilebilir.

## Testler

```bash
brew install bats-core
bats tests/macupdate.bats
```

Her test yalıtılmış bir `HOME` ve yalnız sahte komutlardan oluşan bir `PATH` kullanır; gerçek sisteme dokunmaz.

## Lisans

[MIT](LICENSE).
