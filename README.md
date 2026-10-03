# SSHphone

Android telefonunuzu **SSH ile bağlanılabilen bir Linux sunucusuna (VDS)** dönüştüren tek dosyalık kurulum scripti.
[Termux](https://termux.dev) üzerinde çalışır, **root gerektirmez**.

## Özellikler

- OpenSSH sunucusu kurulumu ve yapılandırması (varsayılan port `8022`)
- Parola ve/veya SSH anahtarı ile giriş, istenirse parola girişini kapatma
- İsteğe bağlı tam Linux dağıtımı (Ubuntu, Debian, Alpine, Arch, Fedora...) — `proot-distro` ile
- SSH ile bağlanınca doğrudan Ubuntu/Debian kabuğuna düşme (`autologin`)
- Telefon uyusa da çalışmaya devam (wake-lock) ve açılışta otomatik başlatma (Termux:Boot)
- SFTP/SCP ile dosya aktarımı
- Port yönlendirmesi olmadan dış ağdan erişim (Cloudflare Tunnel) veya Tailscale desteği
- Girişte cihaz bilgisi ekranı (bellek, disk, batarya), etkileşimli menü

## Gereksinimler

| Uygulama | Zorunlu mu? | Nereden |
|---|---|---|
| Termux | Evet | [F-Droid](https://f-droid.org/packages/com.termux/) veya [GitHub](https://github.com/termux/termux-app/releases) |
| Termux:Boot | Açılışta otomatik başlatma için | [F-Droid](https://f-droid.org/packages/com.termux.boot/) |
| Tailscale | Her yerden erişim için (önerilen) | Play Store / F-Droid |

> Termux ve eklentileri **aynı kaynaktan** (hepsi F-Droid ya da hepsi GitHub) kurulmalıdır.

## Kurulum

Termux'u açın ve çalıştırın:

```bash
pkg install -y curl
curl -fsSL https://raw.githubusercontent.com/mesutozansoftware/SSHphone/main/sshphone.sh -o sshphone.sh
bash sshphone.sh
```

Sihirbaz sırasıyla şunları sorar: SSH portu, giriş parolası, (isteğe bağlı) SSH açık anahtarı,
(isteğe bağlı) Linux dağıtımı, depolama izni ve wake-lock. Sonunda bağlantı komutunu gösterir:

```
ssh -p 8022 u0_a123@192.168.1.42
```

Kurulumdan sonra script `sshphone` komutu olarak kullanılabilir.

## Bilgisayardan bağlanma

```bash
ssh -p 8022 <kullanıcı>@<telefon_ip>          # kullanıcı/IP: sshphone info
scp -P 8022 dosya.txt <kullanıcı>@<ip>:~/      # dosya gönderme
sftp -P 8022 <kullanıcı>@<ip>                  # veya FileZilla / WinSCP
```

Parolasız giriş için bilgisayarınızda anahtar oluşturup ekleyin:

```bash
# Bilgisayarda
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub        # çıktıyı kopyalayın
# Telefonda
sshphone add-key "ssh-ed25519 AAAA... kullanici@pc"
sshphone password-auth off       # isteğe bağlı: yalnızca anahtarla giriş
```

## Komutlar

| Komut | Açıklama |
|---|---|
| `sshphone` | Etkileşimli menü |
| `sshphone info` | IP, port, kullanıcı ve bağlantı komutu |
| `sshphone start` / `stop` / `restart` | SSH sunucusunu yönetir (açık oturumlar kopmaz) |
| `sshphone status` | Durum ve son günlük satırları |
| `sshphone port 2222` | Portu değiştirir (1024–65535) |
| `sshphone password` | Giriş parolasını değiştirir |
| `sshphone add-key <anahtar\|dosya>` / `keys` | SSH anahtarı ekler / listeler |
| `sshphone password-auth on\|off` | Parola girişini açar/kapatır |
| `sshphone distro [ubuntu]` | Linux dağıtımı kurar |
| `sshphone linux` | Kurulu dağıtıma girer |
| `sshphone autologin on\|off` | SSH girişinde doğrudan dağıtıma geçer |
| `sshphone tunnel` | Cloudflare tüneli ile dış ağdan erişim |
| `sshphone wakelock on\|off` | Uyku engelleme |
| `sshphone autostart on\|off` | Termux açılınca sshd'yi başlatma |
| `sshphone update` | Scripti günceller |
| `sshphone uninstall` | Kaldırır |

`autologin` açıkken Termux kabuğuna ulaşmak için dağıtımda `exit` yazın ya da `ssh -p 8022 kullanici@ip -t bash` kullanın.

## Dış ağdan (internetten) erişim

Mobil veri ve çoğu ev ağı (CGNAT) doğrudan dışarıdan erişime izin vermez. Seçenekler:

1. **Tailscale (önerilen):** Telefona ve bilgisayara Tailscale uygulamasını kurup aynı hesapla giriş yapın.
   `sshphone info` çıktısında `100.x.x.x` adresi görünür; her yerden `ssh -p 8022 kullanici@100.x.x.x`.
2. **Cloudflare Tunnel:** `sshphone tunnel` çalıştırın, verilen `*.trycloudflare.com` adresine bilgisayarda
   [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) ile bağlanın:
   ```bash
   ssh -o ProxyCommand="cloudflared access ssh --hostname %h" kullanici@xxxx.trycloudflare.com
   ```
   Tünelin arka planda açık kalması için: `tmux new -s tunnel 'sshphone tunnel'`
3. **Modemde port yönlendirme:** Wi-Fi'de, modeminizden 8022 portunu telefonun yerel IP'sine yönlendirin
   (bu durumda mutlaka `password-auth off` kullanın).

## Telefonun sürekli açık kalması için

- **Pil optimizasyonu:** Ayarlar → Uygulamalar → Termux → Pil → *Kısıtlama yok*.
- **Wake-lock:** Kurulumda açılır; Termux bildiriminde "Release wakelock" düğmesi görünür.
- **Termux:Boot:** Kurduktan sonra bir kez açın; telefon yeniden başlayınca SSH otomatik açılır.
- **Android 12+ "phantom process killer":** Uzun süren süreçleri öldürebilir. Bilgisayardan ADB ile kapatın:
  ```bash
  # Android 12L / 13+
  adb shell "settings put global settings_enable_monitor_phantom_procs false"
  # Android 12
  adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
  adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  ```
  Android 14+ sürümlerinde aynı ayar Geliştirici seçenekleri → *Alt süreç kısıtlamalarını devre dışı bırak* altında da bulunur.

## Sınırlamalar

- Root olmadan 1024 altındaki portlar (ör. 22) kullanılamaz.
- `proot` gerçek bir sanal makine değildir: `systemd`, Docker ve çekirdek modülleri çalışmaz,
  performans yerel Termux'tan biraz düşüktür.
- Termux'ta kullanıcı adı önemsizdir; herhangi bir adla parola/anahtar doğruysa giriş yapılır.

## Kaldırma

```bash
sshphone uninstall
```

Bu komut SSHphone ayarlarını, `~/.bashrc` kancasını ve açılış betiğini kaldırır; Termux paketlerini ve
dağıtımları silmez (`pkg uninstall openssh`, `proot-distro remove ubuntu`).
