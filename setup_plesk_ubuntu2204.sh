#!/usr/bin/env bash
set -euo pipefail

# Ubuntu 22.04 LTS için: Plesk + PHP 7.4, 8.0-8.4 + ionCube + UFW + Plesk Firewall
# Not: PHP 7.1/7.2/7.3 bu dağıtımda resmi depolarda yoktur. Script, mevcut değilse atlar.

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; CYAN="\033[1;36m"; NC="\033[0m"
log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
info() { printf "${CYAN}[*]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*"; }

SUCCESSES=()
WARNINGS=()
FAILURES=()

record_success(){ SUCCESSES+=("$1"); }
record_warning(){ WARNINGS+=("$1"); }
record_failure(){ FAILURES+=("$1"); }

banner(){
  echo -e "${CYAN}==============================================${NC}"
  echo -e "${CYAN}   ArslanSoft Plesk Otomatik Kurulum Scripti   ${NC}"
  echo -e "${CYAN}==============================================${NC}"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Bu script root olarak çalıştırılmalıdır."; exit 1
  fi
}

setup_basics() {
  export DEBIAN_FRONTEND=noninteractive
  info "Sistem güncellemeleri uygulanıyor"
  if apt update && apt -y full-upgrade; then record_success "Apt upgrade"; else record_failure "Apt upgrade"; fi
  if apt -y install tzdata curl ca-certificates software-properties-common apt-transport-https ufw lsb-release unzip; then record_success "Temel paketler"; else record_failure "Temel paketler"; fi
  info "Saat dilimi Europe/Istanbul ayarlanıyor"
  if timedatectl set-timezone Europe/Istanbul; then record_success "Timezone"; else record_warning "Timezone (eldeki değer korunmuş olabilir)"; fi
  timedatectl set-local-rtc 0 || true
}

setup_firewall() {
  info "UFW temel kuralları uygulanıyor"
  ufw default deny incoming || true
  ufw default allow outgoing || true
  for p in 22 80 443 8443 8447; do ufw allow ${p}/tcp || true; done
  # Plesk lisans sunucusu çıkış portu
  ufw allow out 5224/tcp || true
  if ufw --force enable; then record_success "UFW aktif"; else record_warning "UFW etkinleştirme"; fi
}

# Bazı ortamlarda Plesk kurulumu sonrası HTTP/HTTPS kuralları tekrar gereksinim
ensure_http_https_open() {
  info "HTTP/HTTPS erişimi kesinleştiriliyor (UFW)"
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw reload || true
  record_success "UFW 80/443 açık ve reload"
}

install_plesk() {
  if ! command -v plesk >/dev/null 2>&1; then
    log "Plesk kurulumu başlatılıyor (stable)"
    if sh <(curl -fsSL https://autoinstall.plesk.com/one-click-installer) --tier stable; then
      record_success "Plesk kuruldu"
    else
      record_failure "Plesk kurulumu"
    fi
  else
    info "Plesk zaten kurulu"
  fi

  info "Plesk Firewall uzantısı etkinleştiriliyor"
  plesk installer add --components ext-firewall || true
  if plesk bin extension --enable firewall; then record_success "Plesk Firewall etkin"; else record_warning "Plesk Firewall etkinleştirme"; fi
}

add_ondrej_ppa() {
  if ! apt-cache policy | grep -qi "ppa.launchpadcontent.net/ondrej/php"; then
    info "Ondřej PHP PPA deposu ekleniyor"
    if add-apt-repository -y ppa:ondrej/php && apt -y update; then record_success "Ondrej PPA"; else record_failure "Ondrej PPA"; fi
  else
    info "Ondřej PPA zaten ekli"
  fi
}

install_php_series() {
  local version="$1"
  info "PHP ${version} paketleri kuruluyor"
  apt -y install \
    php${version}-fpm php${version}-cli php${version}-common php${version}-opcache \
    php${version}-mbstring php${version}-xml php${version}-zip php${version}-curl \
    php${version}-gd php${version}-intl php${version}-soap php${version}-mysql || {
      warn "PHP ${version} paketleri bulunamadı, atlanıyor."; record_warning "PHP ${version} paket yok"; return 0; }

  echo "date.timezone=Europe/Istanbul" > /etc/php/${version}/fpm/conf.d/99-timezone.ini || true
  echo "date.timezone=Europe/Istanbul" > /etc/php/${version}/cli/conf.d/99-timezone.ini || true
  systemctl enable --now php${version}-fpm || true

  # Plesk handler ekle
  local hid="oss-php${version/./}"
  info "Plesk handler ekleniyor: ${hid}"
  plesk bin php_handler --remove "${hid}" 2>/dev/null || true
  plesk bin php_handler --add \
    -id "${hid}" \
    -displayname "PHP ${version} (OS PPA) FPM" \
    -type fpm \
    -path "/usr/sbin/php-fpm${version}" \
    -service "php${version}-fpm" \
    -phpini "/etc/php/${version}/fpm/php.ini" \
    -poold "/etc/php/${version}/fpm/pool.d" \
    -clipath "/usr/bin/php${version}" && record_success "Handler ${version}" || { warn "Handler kayıt uyarısı: ${version}"; record_warning "Handler ${version}"; }
}

install_plesk_php_components() {
  # Plesk’in kendi PHP’leri (mevcut ise)
  info "Plesk PHP 8.0/8.1/8.2 bileşenleri deneniyor"
  plesk installer add --components plesk-php80 plesk-php81 plesk-php82 || record_warning "Plesk PHP 8.0/8.1/8.2 eklenemedi (opsiyonel)"
}

install_ioncube_for_version() {
  local version="$1"; local zenddir
  zenddir="/usr/lib/php/$(php-config --extension-dir 2>/dev/null | awk -F/ '{print $(NF-1)}' || echo "$(ls /usr/lib/php | head -n1)")"
  # Hedef extension dizini doğrudan sürüme göre belirle
  local extdir="/usr/lib/php/$(ls /usr/lib/php | head -n1)"
  [ -d "/usr/lib/php/${extdir}" ] && extdir="/usr/lib/php/${extdir}"
  
  local so_target="/usr/lib/php/modules/ioncube_loader_lin_${version}.so"
  [ -d "/usr/lib/php/modules" ] || mkdir -p /usr/lib/php/modules
  cp "ioncube/ioncube_loader_lin_${version}.so" "${so_target}"

  # conf.d dosyalarını yaz
  for sapi in fpm cli; do
    local ini_dir="/etc/php/${version}/${sapi}/conf.d"
    [ -d "${ini_dir}" ] || continue
    echo "zend_extension=${so_target}" > "${ini_dir}/00-ioncube.ini"
  done
}

install_ioncube() {
  info "ionCube Loader indiriliyor"
  cd /root
  curl -fsSL -o ioncube_loaders_lin_x86-64.zip https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.zip
  unzip -o ioncube_loaders_lin_x86-64.zip >/dev/null

  for v in 7.4 8.0 8.1 8.2 8.3 8.4; do
    if [ -d "/etc/php/${v}" ]; then
      info "ionCube etkinleştiriliyor: PHP ${v}"
      install_ioncube_for_version "${v}" && record_success "ionCube ${v}" || { warn "ionCube ${v} kurulamadı"; record_warning "ionCube ${v}"; }
      systemctl restart php${v}-fpm || true
    fi
  done
}

show_summary() {
  echo
  log "Kurulum özeti"
  timedatectl | sed -n '1,6p'
  plesk version || true
  echo "--- PHP Handler Listesi ---"
  plesk bin php_handler --list || true
  echo "--- Açık Portlar ---"
  ss -ltnp | grep -E ':(22|80|443|8443|8447)\b' || true

  echo
  echo -e "${GREEN}Başarılı adımlar:${NC}"
  ((${#SUCCESSES[@]})) && printf ' - %s\n' "${SUCCESSES[@]}" || echo ' - (yok)'
  echo -e "${YELLOW}Uyarılar:${NC}"
  ((${#WARNINGS[@]})) && printf ' - %s\n' "${WARNINGS[@]}" || echo ' - (yok)'
  echo -e "${RED}Hatalar:${NC}"
  ((${#FAILURES[@]})) && printf ' - %s\n' "${FAILURES[@]}" || echo ' - (yok)'
}

main() {
  banner
  require_root
  setup_basics
  setup_firewall
  install_plesk
  add_ondrej_ppa

  # Native: 7.4 ve 8.0-8.4
  install_php_series 7.4
  install_php_series 8.0
  install_php_series 8.1
  install_php_series 8.2
  # 8.3 ve 8.4 çoğunlukla Plesk paketleriyle gelir; PPA ile de deneriz
  install_php_series 8.3 || true
  install_php_series 8.4 || true

  # Plesk’in kendi PHP 8.0/8.1/8.2 bileşenlerini de yüklemeyi dene
  install_plesk_php_components

  # ionCube
  install_ioncube

  warn "PHP 7.1/7.2/7.3 Ubuntu 22.04 üzerinde resmi paket olarak sunulmaz. Gerekirse ayrı legacy VM veya Docker önerilir."

  # Güvenlik duvarında 80/443 açık olduğundan emin ol
  ensure_http_https_open

  show_summary
  log "Kurulum tamamlandı. Panele: https://$(curl -s ifconfig.me):8443"
}

main "$@"


