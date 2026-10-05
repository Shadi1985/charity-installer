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
#   1. يسأل عن اسم المؤسسة والنطاق والبريد والترخيص — ثم لا يسأل شيئًا
#   2. بالترخيص (من مطوّر المنصة): يصل إلى المستودع فورًا عبر بوابة
#      التحديثات، بلا مفتاح ولا انتظار
#      بلا ترخيص: يولّد مفتاح نشر، وينتظر حتى يضيفه المطوّر في GitHub
#   3. يستنسخ المنصة، ويثبّت Docker إن غاب، ويشغّل install.sh
#
#  الترخيص يُمرَّر أيضًا دون سؤال:
#      curl … | sudo LICENSE=chl_… bash
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
# مجلد root ثابت لا $HOME: مع `sudo -E` أو إعداد sudo يُبقي HOME يصير
# $HOME مجلد المستخدم العادي، فتُكتب فيه ملفات يملكها root وتنكسر
# مفاتيحه. و ssh نفسه لا يقرأ $HOME بل مجلد المستخدم من النظام — فالمفتاح
# هناك لن يجده أصلًا. السكربت يعمل بـ root، وcron الوكيل كذلك.
SSH_DIR=/root/.ssh
KEY="$SSH_DIR/charity_deploy"
# اسم مستعار لـ GitHub خاص بالمنصة: لا يمسّ أي اتصال آخر بـ GitHub على
# الخادم، ولا يتعارض مع مفاتيح أخرى إن وُجدت.
HOST_ALIAS="charity-github"

# بصمة GitHub الرسمية (ed25519). مثبّتة هنا لا مقبولة عند أول اتصال:
# لا أحد على الخادم ليتحقق منها، والقبول الأعمى يسهّل التجسس على
# الاتصال. البصمة: SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
#
# ⚠ GitHub دوّر مفتاح RSA في 2023. إن دوّر هذا أيضًا فشل التحقق، فيتوقف
# السكربت ويطلب القيمة الجديدة — من https://api.github.com/meta (ssh_keys)
# — تُمرَّر دون انتظار تحديث هذا الملف:
#     curl … | sudo GITHUB_HOSTKEY="github.com ssh-ed25519 …" bash
GITHUB_HOSTKEY="${GITHUB_HOSTKEY:-github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl}"

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
ORG="${ORG:-}"; DOMAIN="${DOMAIN:-}"; EMAIL="${EMAIL:-}"; LICENSE="${LICENSE-__ask__}"
[ -n "$ORG" ] || ORG=$(ask "  اسم المؤسسة (لتسمية المفتاح، مثل: الأمل-والعمل): ")
# تسمية للمفتاح لا أكثر: المسافات تصير شرطات، ولا أسطر.
ORG=$(printf '%s' "$ORG" | tr -d '\r\n' | tr -s ' ' '-')
[ -n "$ORG" ] || die "اسم المؤسسة مطلوب."
[ -n "$DOMAIN" ] || DOMAIN=$(ask "  نطاق المنصة (مثل: projects.example.org): ")
DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
[ -n "$DOMAIN" ] || die "النطاق مطلوب."
[ -n "$EMAIL" ] || EMAIL=$(ask "  بريد الإدارة (لشهادة HTTPS): ")
# ما يُكتب في طرفية المتصفح قد يحمل حرفًا خفيًا: تبديل لغة لوحة المفاتيح
# ترك في التجربة نصف حرف عربي (البايت 0xD9) أول البريد، فقبله الفحص ورفضته
# جهات الشهادات. النطاق والبريد لاتينيان، فيُحذف ما سوى حروفهما.
DOMAIN=$(printf '%s' "$DOMAIN" | LC_ALL=C tr -cd 'A-Za-z0-9.-')
EMAIL=$(printf '%s' "$EMAIL" | LC_ALL=C tr -cd 'A-Za-z0-9.@_+-')
[[ "$EMAIL" =~ ^[^@]+@[^@]+.[A-Za-z]{2,}$ ]] || die "بريد غير صالح: $EMAIL"
# جهات الشهادات ترفض البريد بنطاق وهمي (test.com وexample.org…)، فلا تصدر
# شهادة HTTPS ولا يفتح الرابط — والخطأ لا يظهر إلا في سجل Caddy بعد التنصيب.
# وقع هذا في التجربة. يُرفض هنا بدل أن يُكتشف هناك. (localhost لا يطلب شهادة عامة.)
[ "$DOMAIN" = localhost ] || case "${EMAIL##*@}" in
  example.com|example.org|example.net|test.com|test|localhost|invalid|*.example|*.test|*.invalid|*.localhost)
    die "البريد $EMAIL بنطاق وهمي — جهات شهادات HTTPS ترفضه فلا يفتح الرابط. استعمل بريدًا حقيقيًا." ;;
esac
if [ "$LICENSE" = __ask__ ]; then
  LICENSE=$(ask "  رقم الترخيص من مطوّر المنصة (Enter إن لم يكن لديك): ")
fi
LICENSE=$(printf '%s' "$LICENSE" | tr -d ' \r\n')
[ -z "$LICENSE" ] || [[ "$LICENSE" =~ ^chl_[A-Za-z0-9]{32}$ ]] \
  || die "رقم الترخيص غير صالح — يبدأ بـ chl_ ويليه 32 حرفًا. انسخه كما أُرسل إليك."

# ---- هل يشير النطاق إلى هذا الخادم؟ ----
# خطأ هنا لا يظهر إلا في آخر التنصيب، حين تفشل شهادة HTTPS بعد دقائق
# من البناء. تحذير لا إيقاف: النطاق خلف Cloudflare (السحابة البرتقالية)
# يشير إلى عناوينها لا إلى الخادم، ويعمل مع ذلك.
if [ "$DOMAIN" != localhost ]; then
  MY_IP=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  # «|| true» داخل الأنبوب: نطاق بلا سجل يُفشل getent، ومع pipefail و
  # set -e يخرج السكربت كله قبل أن يحذّر — وقع هذا في التجربة.
  DNS_IPS=$({ getent ahostsv4 "$DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ -z "$DNS_IPS" ]; then
    echo
    echo "  ⚠ النطاق $DOMAIN لا يشير إلى أي عنوان بعد."
    echo "    أضف سجل A إلى عنوان هذا الخادم ${MY_IP:+($MY_IP)} قبل أن يصل التنصيب إلى شهادة HTTPS."
  elif [ -n "$MY_IP" ] && [[ " $DNS_IPS" != *" $MY_IP "* ]]; then
    echo
    echo "  ⚠ النطاق $DOMAIN يشير إلى $DNS_IPS — وعنوان هذا الخادم $MY_IP."
    echo "    إن لم يكن خلف Cloudflare فصحّح سجل A، وإلا فشلت شهادة HTTPS في آخر التنصيب."
  else
    echo "  ✓ النطاق يشير إلى هذا الخادم"
  fi
fi

# ---- 2) الأدوات الأساسية ----
step "الأدوات الأساسية"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# cron لوكيل التحديث؛ والباقي لما بعده.
apt-get install -y -qq git curl openssl ca-certificates cron >/dev/null
systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
echo "  ✓ git و curl و openssl و cron"

# ---- 3) الوصول إلى المستودع ----
if [ -n "$LICENSE" ]; then
  # بالترخيص: لا مفتاح على الخادم. مساعد git يأخذ من بوابة التحديثات
  # رمزًا صلاحيته ساعة عند كل جلب. يُكتب هنا قبل الاستنساخ، والمستودع
  # لم يصل بعد — لذلك نسخته مضمَّنة (الأصل: scripts/git-credential-charity،
  # واختبار يتحقق أن النسختين متطابقتان).
  step "الترخيص"
  install -d -m 700 /etc/charity
  cat > /usr/local/bin/git-credential-charity <<'CHARITY_HELPER'
#!/usr/bin/env bash
# =====================================================================
#  مساعد git — رمز قصير من بوابة التحديثات بدل مفتاح ثابت
# =====================================================================
#  git يستدعيه عند كل جلب من GitHub:  git-credential-charity get
#  فيرسل ترخيص المؤسسة وإصدارها إلى البوابة، ويعيد رمزًا صلاحيته ساعة
#  لقراءة مستودع المنصة وحده.
#
#  يعيش خارج المستودع (/usr/local/bin) لا في scripts/: الرجوع إلى
#  إصدار أقدم يغيّر ما في الشجرة، ولا يجوز أن يكسر ذلك الجلب نفسه.
#  والترخيص في /etc/charity/license (root، صلاحية 600).
#
#  ⚠ نسخة منه مضمَّنة في scripts/bootstrap.sh (يكتبها قبل الاستنساخ،
#  والمستودع لم يصل بعد). اختبار يتحقق أن النسختين متطابقتان.
# =====================================================================
set -u

ACTION="${1:-}"
HOST=""
# git يرسل الطلب أسطرًا ثم سطرًا فارغًا، ويجب أن يُقرأ كله قبل الرد.
while IFS= read -r line && [ -n "$line" ]; do
  case "$line" in host=*) HOST="${line#host=}" ;; esac
done

# «store» و«erase»: لا شيء يُحفظ، فلا شيء يُمحى.
[ "$ACTION" = get ] || exit 0
[ "$HOST" = github.com ] || exit 0

CONF=/etc/charity
# ملف بديل يُجرَّب به ترخيص جديد قبل أن يحلّ محل القائم.
LICENSE_FILE="${CHARITY_LICENSE_FILE:-$CONF/license}"
[ -r "$LICENSE_FILE" ] || exit 0
LICENSE="$(tr -d ' \r\n' < "$LICENSE_FILE")"
GATEWAY="$(tr -d ' \r\n' 2>/dev/null < "$CONF/gateway" || true)"
GATEWAY="${GATEWAY:-https://updates.irtiqa.academy}"

# الإصدار العامل الآن يُرسَل مع الطلب: هكذا يعرف المطوّر من على أي إصدار.
VERSION="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"

BODY="$(mktemp)"; HDR="$(mktemp)"
trap 'rm -f "$BODY" "$HDR"' EXIT

# الترخيص في ملف إعداد يُقرأ من المدخل لا في سطر الأوامر: سطر الأوامر
# يقرؤه كل مستخدم على الخادم بـ ps.
CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$LICENSE" \
  | curl -sS --max-time 20 -K - -o "$BODY" -D "$HDR" -w '%{http_code}' \
      -X POST --data-urlencode "version=$VERSION" "$GATEWAY/v1/credential" 2>/dev/null || echo 000)"

if [ -n "$TOP" ] && [ -d "$TOP/updates" ]; then
  # آخر رد من البوابة: صفحة التحديثات تقول منه «موقوفة» أو «الترخيص
  # غير معروف» بدل «الوكيل متوقف».
  printf '{ "code": %s, "at": "%s" }\n' "$((10#$CODE))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$TOP/updates/gateway.json"
  chmod 0644 "$TOP/updates/gateway.json" 2>/dev/null || true

  # حدّ الإصدار (إن ثبّت المطوّر المؤسسة على إصدار): يقرؤه الوكيل و update.sh.
  if [ "$CODE" = 200 ]; then
    MAX="$(grep -i '^x-max-version:' "$HDR" | head -1 | cut -d: -f2- | tr -d ' \r\n' || true)"
    if [ -n "$MAX" ]; then
      printf 'MAX_VERSION=%s\n' "$MAX" > "$TOP/updates/.policy"
    else
      rm -f "$TOP/updates/.policy"
    fi
  fi
fi

case "$CODE" in
  200) cat "$BODY" ;;
  401) echo "✗ بوابة التحديثات: الترخيص غير معروف ($LICENSE_FILE)." >&2 ;;
  403) echo "✗ بوابة التحديثات: تحديثات هذه المؤسسة موقوفة — تواصل مع مطوّر المنصة. المنصة تبقى تعمل." >&2 ;;
  429) echo "✗ بوابة التحديثات: طلبات كثيرة — أعد المحاولة بعد دقيقة." >&2 ;;
  *)   echo "✗ بوابة التحديثات غير متاحة الآن ($CODE). المنصة تبقى تعمل، والتحديث يُعاد لاحقًا." >&2 ;;
esac
exit 0
CHARITY_HELPER
  chmod 755 /usr/local/bin/git-credential-charity
  REPO_URL="https://github.com/$REPO_PATH.git"
  # يُجرَّب من ملف مؤقت قبل أن يحلّ محل ترخيص قائم: رقم خاطئ في إعادة
  # تشغيل لا يجوز أن يكسر خادمًا يعمل.
  NEW_LIC="$(mktemp /etc/charity/.license.XXXXXX)"
  printf '%s\n' "$LICENSE" > "$NEW_LIC"
  if ! CHARITY_LICENSE_FILE="$NEW_LIC" GIT_TERMINAL_PROMPT=0 \
       git -c credential.helper= -c credential.helper=charity ls-remote --tags "$REPO_URL" >/dev/null; then
    rm -f "$NEW_LIC"
    die "تعذّر الوصول بالترخيص — الرسالة أعلاه تقول السبب، ولم يتغيّر شيء. تحقق من الرقم، أو راسل مطوّر المنصة."
  fi
  chmod 600 "$NEW_LIC"
  mv -f "$NEW_LIC" /etc/charity/license
  echo "  ✓ الترخيص مفعَّل"
else
REPO_URL="git@$HOST_ALIAS:$REPO_PATH.git"
step "مفتاح الوصول"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
if [ -f "$KEY" ]; then
  echo "  يُستعمل المفتاح الموجود على هذا الخادم."
else
  ssh-keygen -q -t ed25519 -f "$KEY" -N "" -C "$ORG"
  echo "  ✓ وُلِّد مفتاح جديد على هذا الخادم"
fi

if ! grep -q "^Host $HOST_ALIAS\$" "$SSH_DIR/config" 2>/dev/null; then
  cat >> "$SSH_DIR/config" <<EOF

# منصة إدارة المشاريع الخيرية — مفتاح نشر للقراءة فقط
Host $HOST_ALIAS
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_DIR/config"
fi
grep -qF "$GITHUB_HOSTKEY" "$SSH_DIR/known_hosts" 2>/dev/null \
  || echo "$GITHUB_HOSTKEY" >> "$SSH_DIR/known_hosts"

has_access() {
  # GitHub يرد برسالة ترحيب ويخرج بـ 1 حتى حين ينجح التحقق (لا shell).
  # فلا يُقرأ رمز الخروج — مع pipefail يُعدّ الأنبوب كله فاشلًا، فينتظر
  # السكربت إلى الأبد والمفتاح مفعَّل. تُقرأ الرسالة وحدها.
  local out
  out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -T "git@$HOST_ALIAS" 2>&1 || true)
  # بصمة GitHub تغيّرت: الانتظار لا يُصلحها، فيتوقف السكربت ويقول لماذا.
  if [[ "$out" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* || "$out" == *"Host key verification failed"* ]]; then
    die "بصمة GitHub لا تطابق المثبّتة في السكربت — ربما دوّرت GitHub مفتاحها.
  تحقق من القيمة الجديدة في https://api.github.com/meta ثم أعد التشغيل هكذا:
      curl … | sudo GITHUB_HOSTKEY=\"github.com ssh-ed25519 …\" bash"
  fi
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
fi  # بلا ترخيص

# ---- 5) الاستنساخ ----
step "المنصة"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "  موجودة في $INSTALL_DIR"
else
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c credential.helper=charity \
    clone --quiet "$REPO_URL" "$INSTALL_DIR"
  [ -z "$LICENSE" ] || git -C "$INSTALL_DIR" config credential.helper charity
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
