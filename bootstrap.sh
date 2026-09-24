#!/usr/bin/env bash
# =====================================================================
#  سكربت الإقلاع — تنصيب المنصة على خادم جديد بلا تقني
# =====================================================================
#  يُنشر نسخةً في مستودع عام صغير (charity-installer)، لأن مستودع المنصة
#  خاص: المؤسسة لا تستطيع أن تنزّل منه شيئًا قبل أن يُضاف مفتاحها.
#
#  على خادم لينكس جديد (Ubuntu/Debian)، سطر واحد:
#
#      curl -fsSL https://raw.githubusercontent.com/Shadi1985/charity-installer/main/bootstrap.sh | sudo bash
#
#  ثم يتولّى الباقي:
#   1. يسأل عن اسم المؤسسة والنطاق والبريد — ثم لا يسأل شيئًا بعدها
#   2. يولّد مفتاح نشر على هذا الخادم، ويعرض جزءه العام
#   3. ينتظر حتى يضيفه المطوّر في GitHub، ويختبر الوصول كل 10 ثوانٍ
#   4. يستنسخ المنصة، ويثبّت Docker إن غاب، ويشغّل install.sh
#
#  المفتاح الخاص يُولَّد هنا ولا يغادر الخادم. ما يُرسَل إلى المطوّر
#  هو الجزء العام وحده — ليس سرًّا، ومن يملكه لا يستطيع به شيئًا.
#
#  آمن للتكرار: من قطعه (Ctrl+C) يعيد السطر نفسه، فيُستعمل المفتاح
#  نفسه ويُكمل من حيث توقف.
#
#  خيار للاختبار أو لمن يريد أن يرى قبل أن ينصّب:
#      … | sudo bash -s -- --no-install      يتوقف بعد الاستنساخ
# =====================================================================
# ---- لماذا دالّة؟ ----
# في «curl … | bash» يقرأ bash السكربت من المدخل سطرًا سطرًا أثناء
# التنفيذ. وأي أمر يقرأ من المدخل (ssh مثلًا) يبتلع بقية السكربت، فيجد
# bash المدخل فارغًا ويخرج «بنجاح» في منتصف الطريق. وقع هذا فعلًا: توقف
# بعد «المفتاح مفعَّل» ولم يستنسخ شيئًا. الدالّة تُقرأ كاملةً قبل أن
# يُنفَّذ منها سطر، فلا يبقى في المدخل ما يُبتلع.
main() {
set -euo pipefail

# ---- ما يتغيّر إن نُقل المستودع ----
REPO_PATH="Shadi1985/projectsPanel"
INSTALL_DIR="${INSTALL_DIR:-/opt/charity}"
KEY="$HOME/.ssh/charity_deploy"
# اسم مستعار لـ GitHub خاص بالمنصة: لا يمسّ أي اتصال آخر بـ GitHub على
# الخادم، ولا يتعارض مع مفاتيح أخرى إن وُجدت.
HOST_ALIAS="charity-github"

# بصمة GitHub الرسمية (ed25519). مثبّتة هنا لا مقبولة عند أول اتصال:
# لا أحد على الخادم ليتحقق منها، والقبول الأعمى يسهّل التجسس على
# الاتصال. البصمة: SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
GITHUB_HOSTKEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

NO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-install) NO_INSTALL=1 ;;
    *) echo "✗ خيار غير معروف: $arg" >&2; exit 1 ;;
  esac
done

die()  { echo; echo "✗ $*" >&2; exit 1; }
step() { echo; echo "── $* ──"; }

# السكربت يصل عبر أنبوب (curl | bash)، فمدخله هو السكربت نفسه لا
# لوحة المفاتيح. الأسئلة تُقرأ من الطرفية مباشرة.
ask() {
  local prompt="$1" var
  [ -r /dev/tty ] || die "لا طرفية للسؤال. شغّله من طرفية تفاعلية."
  read -rp "$prompt" var < /dev/tty
  printf '%s' "$var"
}

echo "════════════════════════════════════════════"
echo "  تنصيب منصة إدارة المشاريع الخيرية"
echo "════════════════════════════════════════════"

# ---- المتطلبات ----
[ "$(id -u)" -eq 0 ] || die "يُشغَّل بصلاحية المدير: أضف sudo قبل bash."
[ "$(uname -s)" = Linux ] || die "هذا السكربت لخوادم لينكس."
command -v apt-get >/dev/null || die "هذا السكربت لـ Ubuntu/Debian. على غيرهما اتبع docs/INSTALL.ar.md."

# ---- 1) الأسئلة — كلها الآن، ثم لا شيء ----
step "بيانات المؤسسة"
# تُمرَّر مسبقًا إن شاء من يشغّله: ORG=… DOMAIN=… EMAIL=… — لمزوّدي
# الاستضافة الذين يشغّلون سكربتًا عند إنشاء الخادم، وللاختبار.
ORG="${ORG:-}"; DOMAIN="${DOMAIN:-}"; EMAIL="${EMAIL:-}"
[ -n "$ORG" ] || ORG=$(ask "  اسم المؤسسة (لتسمية المفتاح، مثل: الأمل-والعمل): ")
# تسمية للمفتاح لا أكثر: المسافات تصير شرطات، ولا أسطر.
ORG=$(printf '%s' "$ORG" | tr -d '\r\n' | tr -s ' ' '-')
[ -n "$ORG" ] || die "اسم المؤسسة مطلوب."
[ -n "$DOMAIN" ] || DOMAIN=$(ask "  نطاق المنصة (مثل: projects.example.org): ")
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
[ -n "$DOMAIN" ] || die "النطاق مطلوب."
[ -n "$EMAIL" ] || EMAIL=$(ask "  بريد الإدارة (لشهادة HTTPS): ")
[[ "$EMAIL" == *@* ]] || die "بريد غير صالح."

# ---- 2) الأدوات الأساسية ----
step "الأدوات الأساسية"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# cron لوكيل التحديث؛ والباقي لما بعده.
apt-get install -y -qq git curl openssl ca-certificates cron >/dev/null
systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
echo "  ✓ git و curl و openssl و cron"

# ---- 3) المفتاح ----
step "مفتاح الوصول"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$KEY" ]; then
  echo "  يُستعمل المفتاح الموجود على هذا الخادم."
else
  ssh-keygen -q -t ed25519 -f "$KEY" -N "" -C "$ORG"
  echo "  ✓ وُلِّد مفتاح جديد على هذا الخادم"
fi

if ! grep -q "^Host $HOST_ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF

# منصة إدارة المشاريع الخيرية — مفتاح نشر للقراءة فقط
Host $HOST_ALIAS
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
fi
grep -qF "$GITHUB_HOSTKEY" "$HOME/.ssh/known_hosts" 2>/dev/null \
  || echo "$GITHUB_HOSTKEY" >> "$HOME/.ssh/known_hosts"

has_access() {
  # GitHub يرد برسالة ترحيب ويخرج بـ 1 حتى حين ينجح التحقق (لا shell).
  # فلا يُقرأ رمز الخروج — مع pipefail يُعدّ الأنبوب كله فاشلًا، فينتظر
  # السكربت إلى الأبد والمفتاح مفعَّل. تُقرأ الرسالة وحدها.
  local out
  out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -T "git@$HOST_ALIAS" 2>&1 || true)
  [[ "$out" == *"successfully authenticated"* ]]
}

# ---- 4) انتظار التفعيل ----
if has_access; then
  echo "  ✓ المفتاح مفعَّل بالفعل"
else
  echo
  echo "════════════════════════════════════════════"
  echo "  أرسل هذا السطر كاملًا إلى مطوّر المنصة:"
  echo
  echo "  $(cat "$KEY.pub")"
  echo
  echo "  (ليس سرًّا — يمكن إرساله بالبريد أو واتساب)"
  echo "════════════════════════════════════════════"
  echo
  echo "  بانتظار تفعيل الوصول… اترك هذه النافذة مفتوحة."
  echo "  (إن أُغلقت: أعد السطر نفسه، فيُكمل بالمفتاح نفسه)"
  START=$(date +%s)
  until has_access; do
    ELAPSED=$(( ($(date +%s) - START) / 60 ))
    printf '\r  ⏳ منذ %s دقيقة…' "$ELAPSED"
    sleep 10
  done
  echo
  echo "  ✓ فُعِّل الوصول"
fi

# ---- 5) الاستنساخ ----
step "المنصة"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "  موجودة في $INSTALL_DIR"
else
  git clone --quiet "git@$HOST_ALIAS:$REPO_PATH.git" "$INSTALL_DIR"
  echo "  ✓ استُنسخت إلى $INSTALL_DIR"
fi
cd "$INSTALL_DIR"

if [ "$NO_INSTALL" -eq 1 ]; then
  echo
  echo "  توقّف قبل التنصيب (--no-install). للإكمال:"
  echo "      cd $INSTALL_DIR && ./scripts/install.sh $DOMAIN $EMAIL"
  exit 0
fi

# ---- 6) Docker ----
step "Docker"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "  ✓ مثبّت"
else
  # السكربت الرسمي من Docker نفسها.
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
  echo "  ✓ ثُبِّت"
fi

# ---- جدار الحماية ----
# يُفعَّل من أول يوم عند أي مزوّد — لا يُفترض أن للمزوّد جدارًا في لوحته.
# ثلاثة منافذ فقط: SSH للدخول، و 80 و 443 للمنصة.
#
# SSH يُسمح به **قبل** التفعيل، ومنفذه يُقرأ من إعداد sshd لا يُفترض 22:
# لو فُعِّل الجدار ومنفذ SSH مغلق لانقطع الاتصال بالخادم نفسه.
#
# تنبيه: Docker يفتح منافذه المنشورة متجاوزًا ufw. هنا لا أثر لذلك —
# المنصة لا تنشر إلا 80 و 443، والقاعدة وغيرها على شبكة Docker الداخلية.
# لكن جدار المزوّد (Cloud Firewall) يصفّي قبل الخادم فلا يتجاوزه شيء،
# فيُنصح به فوق هذا حيث يتوفّر.
step "جدار الحماية"
command -v ufw >/dev/null || apt-get install -y -qq ufw >/dev/null
SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u)
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
for p in $SSH_PORTS; do ufw allow "$p/tcp" >/dev/null; done
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
echo "  ✓ مفعَّل: SSH ($(echo $SSH_PORTS | tr ' ' ',')) و 80 و 443 فقط"

# ---- 7) التنصيب ----
exec ./scripts/install.sh "$DOMAIN" "$EMAIL"
}

main "$@"
