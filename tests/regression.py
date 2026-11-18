"""Extracted-function regression; no installer entrypoint or host services."""
import pathlib,re,subprocess,tempfile,unittest,os
SRC=(pathlib.Path(__file__).resolve().parents[1]/'install.sh').read_text()
def extract(n):
 m=re.search(r'^'+n+r'\(\) \{[^\n]*\n.*?^\}',SRC,re.M|re.S)
 one=re.search(r'^'+n+r'\(\) \{.*\}\s*$',SRC,re.M)
 if one: return one[0]
 assert m,n
 return m[0]
class Tests(unittest.TestCase):
 def run_case(self,names,body):
  with tempfile.TemporaryDirectory(prefix='encryption-test-') as d:
   setup='''set -euo pipefail
RUN="$PWD"; XRAY_BIN="$RUN/core"; XRAY_CONFIG="$RUN/config.json"; ENCRYPTION_INFO="$RUN/encryption.info"; REALITY_INFO="$RUN/reality.info"; SUBSCRIPTION_INFO="$RUN/link"; ROLLBACK_DIR=""; INSTALL_ROLLBACK_DIR=""
AUTH_MODE=mlkem768; TRAFFIC_MODE=native
C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_MAGENTA=''
error() { printf 'ERROR %s\\n' "$*" >&2; }; warning() { :; }; info() { :; }; success() { :; }; print_step() { :; }; cecho() { :; }; print_divider() { :; }
systemctl() { [[ "$*" = 'show -p ActiveState xray' ]] && printf 'ActiveState=inactive\\n'; }; kill() { exit 99; }; pkill() { exit 99; }; pgrep() { return 99; }; apt-get() { exit 99; }; curl() { exit 99; }; sleep() { :; }
'''
   if 'restore_install_snapshot' in names:
    names=list(dict.fromkeys(names+['xray_pids','stop_xray_processes','clear_rollback']))
    setup+='\npgrep() { return 1; }\n'
   if 'on_exit' in names:
    names=list(dict.fromkeys(names+['clear_rollback']))
   if any(n in names for n in ('rollback_config', 'restore_install_snapshot')) and 'restore_file()' in SRC:
    names=list(dict.fromkeys(names+['restore_file']))
   if any(n in names for n in ('show_subscription','xray_status_line')) and 'link_config()' in SRC:
    names=list(dict.fromkeys(names+['link_config']))
   if 'valid_ipv6' in names:
    names=list(dict.fromkeys(names+['valid_ipv4']))
   if any(n in names for n in ('write_config','modify_config','begin_install_snapshot','restore_install_snapshot')) and 'xray_active_state()' in SRC:
    names=list(dict.fromkeys(names+['xray_active_state']))
   parts=[]
   for n in names:
    text=extract(n)
    if n != 'normalize_official_writes':
     for a,b in [('/etc/systemd/system',d+'/system'),('/usr/local/share/xray',d+'/geo'),('/usr/local/etc/xray',d+'/etc'),('/var/log/xray',d+'/logs'),('/tmp/xray-',d+'/snapshot-'),('/proc/',d+'/proc/')]:text=text.replace(a,b)
    parts.append(text)
   text='\n'.join(parts)
   f=pathlib.Path(d)/'fixture.sh';f.write_text(setup+text+'\n'+body)
   o=subprocess.run(['bash',str(f)],cwd=d,text=True,capture_output=True,timeout=15)
   self.assertEqual(o.returncode,0,o.stdout+o.stderr);return o
 def test_mainpid_without_modern_value_flag(self):
  self.run_case(['xray_main_pid'],r'''
systemctl() { [[ "$*" != *--value* ]] || return 1; printf 'MainPID=12\n'; }
readlink() { printf '%s' "$XRAY_BIN"; }
[[ $(xray_main_pid) = 12 ]]
for reply in MainPID=0 MainPID=bad $'MainPID=12\nMainPID=13'; do
 systemctl() { printf '%s\n' "$reply"; }
 if xray_main_pid; then exit 81; fi
done
''')
 def test_service_account_uses_effective_properties(self):
  self.run_case(['service_account'],r'''
systemctl() {
 [[ "$*" != *--value* ]] || return 1
 case "$*" in *User*) printf 'User=root\n';; *Group*) printf 'Group=root\n';; *) return 1;; esac
}
[[ $(service_account) = root:root ]]
systemctl() { return 1; }
if service_account; then exit 81; fi
''')
 def test_modify_preserves_stopped_service(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { [[ "$1" != is-active ]] || return 1; if [[ "$1" = show ]]; then printf 'ActiveState=inactive\n'; fi; }
write_config() { touch written; }
restart_xray() { touch wrongly-started; }
clear_rollback() { :; }; show_subscription() { :; }
modify_config || exit 81
[[ -f written && ! -e wrongly-started ]]
''')
 def test_failed_modify_stop_preserves_snapshot(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; else [[ "$1" != stop ]]; fi; }
write_config() { :; }
restart_xray() { return 1; }
rollback_config() { touch wrongly-restored; }
if modify_config; then exit 81; fi
[[ ! -e wrongly-restored ]]
''')
 def test_public_ip_rejects_bad_cache_and_response(self):
  self.run_case(['public_ip','valid_ipv4','valid_ipv6'],r'''
mkdir -p "$RUN/etc"
printf 'bad@host/path\n' > "$RUN/etc/.public-ip"
curl() { if [[ "$*" = -4* ]]; then printf '203.0.113.7'; else return 1; fi; }
[[ $(public_ip) = 203.0.113.7 ]]
printf '001.2.3.4\n' > "$RUN/etc/.public-ip"
curl() { if [[ "$*" = -4* ]]; then printf '999999999999999999999.1.1.1'; else printf '2001:db8::7'; fi; }
[[ $(public_ip) = '[2001:db8::7]' ]]
''')
 def test_keygen_partial_failure_is_rejected(self):
  self.run_case(['generate_reality_keys','validate_reality_key'],r'''
printf '#!/bin/sh\nprintf "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n"\nexit 7\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
if generate_reality_keys; then exit 81; fi
''')
 def test_encryption_keygen_partial_failure_is_rejected(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['generate_encryption_pair','extract_vlessenc_value','validate_encryption_token','valid_appearance'],r'''
printf '#!/bin/sh\n"%s" vlessenc\nexit 7\n' "$XRAY_TEST_BINARY" > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
if generate_encryption_pair; then exit 81; fi
''')
 def test_invalid_cli_never_installs_dependencies(self):
  for args in ('install --unknown', 'install --port', 'install --port 0', 'install --auth invalid', 'install --short-id aa'):
   with self.subTest(args=args):
    self.run_case(['main','valid_port','valid_auth','valid_appearance','valid_uuid','show_help'],r'''
    require_root_and_dependencies() { touch dependencies; }
    show_help() { :; }
    cat() { printf '00000000-0000-4000-8000-000000000000'; }
    ''' + f'if (main {args}); then exit 81; fi\n[[ ! -e dependencies ]]\n')
 def test_real_modify_switches_both_directions(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  names=['modify_config','valid_port','valid_uuid','valid_sni','valid_short_id','valid_appearance','current_port','extract_vlessenc_value','validate_encryption_token','generate_encryption_pair','validate_reality_key','generate_reality_keys','write_config','clear_rollback','rollback_config']
  self.run_case(names,r'''
XRAY_BIN="$XRAY_TEST_BINARY"
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }
read() { if [[ "$*" = *' -p '* ]]; then case "${!#}" in choice) choice=2;; input) input='';; esac; else builtin read "$@"; fi; }
restart_xray() { "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; }
show_subscription() { :; }
pair=$(generate_encryption_pair); IFS='|' read -r dec enc <<< "$pair"
write_config 18443 00000000-0000-4000-8000-000000000000 "$dec" "$enc" encryption
clear_rollback
jq '.dns={servers:["1.1.1.1"]}' "$XRAY_CONFIG" > extra; mv extra "$XRAY_CONFIG"
for expected in reality none; do
 modify_config || exit 81
 jq -e --arg expected "$expected" '(.inbounds[0].streamSettings.security // "none")==$expected and .dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
 [[ -z "$ROLLBACK_DIR" ]]
done
''')
 def test_public_ip_cache_and_write_failures(self):
  self.run_case(['public_ip','valid_ipv4','valid_ipv6'],r'''
curl() { printf '203.0.113.9'; }
[[ $(public_ip) = 203.0.113.9 ]]
mkdir -p "$RUN/etc"
printf '[2001:db8::9]\n' > "$RUN/etc/.public-ip"
curl() { return 99; }
[[ $(public_ip) = '[2001:db8::9]' ]]
touch -d '2 days ago' "$RUN/etc/.public-ip"
curl() { [[ "$*" = -4* ]] && printf '203.0.113.9' || return 1; }
[[ $(public_ip) = 203.0.113.9 ]]
rm "$RUN/etc/.public-ip"; mkdir "$RUN/etc/.public-ip"
[[ $(public_ip) = 203.0.113.9 ]]
curl() { return 1; }
if public_ip; then exit 81; fi
''')
 def test_official_geodata_write_failure_is_fatal(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['run_official_installer','normalize_official_writes'],r'''
XRAY_INSTALL_URL=fixture XRAY_INSTALL_SHA256=fixture
curl() { cat "$PINNED_INSTALLER"; }
sha256sum() { return 0; }
bash() {
 local file="$1"
 awk '/^install_geodata\(\)/ {inside=1} inside {print} inside && /^}/ {exit}' "$file" > "$RUN/geodata.sh"
 cat >> "$RUN/geodata.sh" <<'SHELL'
TMP_DIRECTORY="$RUN/download"; DAT_PATH="$RUN/data"; XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1; PROXY=''
mkdir -p "$DAT_PATH"
curl() { local output; while [[ $# -gt 0 ]]; do if [[ "$1" = -o ]]; then output="$2"; shift 2; else shift; fi; done; printf fixture > "$output"; }
sha256sum() { return 0; }
install() { return 1; }
install_geodata
SHELL
 command bash "$RUN/geodata.sh"
}
if run_official_installer install-geodata; then exit 81; fi
''')
 def test_official_core_write_guards(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['normalize_official_writes'],r'''
cp "$PINNED_INSTALLER" official
normalize_official_writes official || exit 81
awk '/^install_file\(\)/ {inside=1} inside {print} inside && /^}/ {exit}' official > "$RUN/core-write.sh"
cat >> "$RUN/core-write.sh" <<'SHELL'
TMP_DIRECTORY="$RUN"; DAT_PATH="$RUN"
install() { [[ "$FAULT" = none ]]; }
install_file xray
printf completed
SHELL
if FAULT=write-failure command bash "$RUN/core-write.sh"; then exit 81; fi
[[ $(FAULT=none command bash "$RUN/core-write.sh") = completed ]]
if normalize_official_writes official; then exit 81; fi
''')
 def test_preserved_config_rejects_multiple_json_documents(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s\n' '{"inbounds":[{"port":443,"settings":{"users":[{"id":"old"}]}}]}' '{}' > "$XRAY_CONFIG"
cp "$XRAY_CONFIG" original
if write_config 443 uuid dec enc encryption '' '' '' '' true; then exit 81; fi
cmp original "$XRAY_CONFIG"
[[ -z "$ROLLBACK_DIR" ]]
''')
 def test_preserved_inbound_port_conflict_rejected(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s' '{"inbounds":[{"port":443,"settings":{"users":[{"id":"old"}]}},{"port":"8000-9000","protocol":"socks"}]}' > "$XRAY_CONFIG"
cp "$XRAY_CONFIG" original
if write_config 8388 uuid dec enc encryption '' '' '' '' true; then exit 81; fi
cmp original "$XRAY_CONFIG"
[[ -z "$ROLLBACK_DIR" ]]
''')
 def test_current_schema_and_legacy_migration(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; validate_reality_key() { :; }; valid_sni() { :; }; valid_short_id() { :; }
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s' '{"inbounds":[{"settings":{"clients":[{"id":"old"},{"id":"extra"}]},"streamSettings":{"network":"tcp","tcpSettings":{"header":{"type":"none"}},"security":"reality","realitySettings":{"dest":"old.example:443","serverNames":["old.example"],"shortIds":["aa","bb"]}}}],"dns":{"servers":["1.1.1.1"]}}' > "$XRAY_CONFIG"
jq '.outbounds=[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6",targetStrategy:"",redirect:"127.0.0.1:80"}}]' "$XRAY_CONFIG" > extra; mv extra "$XRAY_CONFIG"
write_config 443 uuid dec enc reality private public new.example 20220701 true
jq -e '.outbounds[0] | .streamSettings.sockopt.domainStrategy=="UseIPv4v6" and .settings.redirect=="127.0.0.1:80" and (.settings|has("domainStrategy")|not) and (.settings|has("targetStrategy")|not)' "$XRAY_CONFIG" >/dev/null
jq -e '.inbounds[0] | (.settings.users[0].id=="uuid" and .settings.users[1].id=="extra" and (.settings|has("clients")|not) and .streamSettings.method=="raw" and (.streamSettings|has("network")|not) and .streamSettings.rawSettings.header.type=="none" and .streamSettings.realitySettings.target=="new.example:443" and (.streamSettings.realitySettings|has("dest")|not))' "$XRAY_CONFIG" >/dev/null
jq -e '.dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
''')
 def test_subscription_reads_current_and_legacy_users(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['show_subscription','valid_port','valid_uuid','validate_encryption_token','valid_appearance','uri_encode','generate_encryption_pair','extract_vlessenc_value'],r'''
XRAY_BIN="$XRAY_TEST_BINARY"
pair=$(generate_encryption_pair); enc=${pair#*|}
printf '%s\n' "$enc" > "$ENCRYPTION_INFO"
public_ip() { printf '[2001:db8::7]'; }
for field in users clients; do
 jq -n --arg field "$field" '{inbounds:[{protocol:"vless",port:443,settings:{($field):[{id:"00000000-0000-4000-8000-000000000000",flow:"xtls-rprx-vision"}],decryption:"old"}}]}' > "$XRAY_CONFIG"
 show_subscription || exit 81
 [[ $(cat "$SUBSCRIPTION_INFO") = 'vless://00000000-0000-4000-8000-000000000000@[2001:db8::7]:443?'* ]]
 [[ $(cat "$SUBSCRIPTION_INFO") = *'type=tcp'* ]]
done
''')
 def test_existing_mldsa_seed_is_exported(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  names=['show_subscription','valid_port','valid_uuid','valid_sni','valid_short_id','validate_reality_key','validate_encryption_token','valid_appearance','uri_encode','generate_encryption_pair','extract_vlessenc_value']
  self.run_case(names,r'''
XRAY_BIN="$XRAY_TEST_BINARY"
pair=$(generate_encryption_pair); enc=${pair#*|}; printf '%s\n' "$enc" > "$ENCRYPTION_INFO"
keys=$("$XRAY_BIN" mldsa65); seed=$(awk '/^Seed:/ {print $2}' <<< "$keys"); verify=$(awk '/^Verify:/ {print $2}' <<< "$keys")
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|www.example.com|aa\n' > "$REALITY_INFO"
jq -n --arg seed "$seed" '{inbounds:[{protocol:"vless",port:443,settings:{users:[{id:"00000000-0000-4000-8000-000000000000",flow:"xtls-rprx-vision"}],decryption:"old"},streamSettings:{security:"reality",realitySettings:{mldsa65Seed:$seed,serverNames:["www.example.com"],shortIds:["aa"]}}}]}' > "$XRAY_CONFIG"
public_ip() { printf '203.0.113.7'; }
show_subscription || exit 81
[[ $(cat "$SUBSCRIPTION_INFO") = *"&pqv=$verify"* ]]
cp "$SUBSCRIPTION_INFO" original
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|www.example.com|bb\n' > "$REALITY_INFO"
if show_subscription; then exit 81; fi
cmp original "$SUBSCRIPTION_INFO"
''')
 def test_official_wrapper_constrains_environment_paths(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['run_official_installer','normalize_official_writes'],r'''
XRAY_INSTALL_URL=fixture XRAY_INSTALL_SHA256=fixture
curl() { cat "$PINNED_INSTALLER"; }
sha256sum() { return 0; }
export DAT_PATH="$RUN/unrelated" JSON_PATH="$RUN/other-config" JSONS_PATH="$RUN/split-config"
bash() {
 [[ "$DAT_PATH" = "$RUN/geo" && "$JSON_PATH" = "$RUN/etc" && -z "$JSONS_PATH" ]]
}
run_official_installer install-geodata || exit 81
[[ "$DAT_PATH" = "$RUN/unrelated" && "$JSON_PATH" = "$RUN/other-config" && "$JSONS_PATH" = "$RUN/split-config" ]]
''')
 def test_official_core_matrix(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['valid_appearance','valid_sni','valid_short_id','extract_vlessenc_value','validate_encryption_token','generate_encryption_pair','validate_reality_key','generate_reality_keys','write_config','clear_rollback','rollback_config'],r'''
XRAY_BIN="$XRAY_TEST_BINARY"
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
for AUTH_MODE in x25519 mlkem768; do
 for TRAFFIC_MODE in native xorpub random; do
  pair=$(generate_encryption_pair); IFS='|' read -r dec enc <<< "$pair"
  keys=$(generate_reality_keys); IFS='|' read -r private public <<< "$keys"
  preserve=false
  for mode in encryption reality encryption; do
   write_config 18443 00000000-0000-4000-8000-000000000000 "$dec" "$enc" "$mode" "$private" "$public" www.example.com 20220701 "$preserve"
   clear_rollback
   jq '.inbounds[0].tag="custom" | .dns={servers:["1.1.1.1"]}' "$XRAY_CONFIG" > "$RUN/extra.json"
   mv "$RUN/extra.json" "$XRAY_CONFIG"
   preserve=true
  done
  jq -e '.inbounds[0].tag=="custom" and .dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
 done
done
''')
 def test_nested_rollback_cleanup_interrupt_keeps_outer_baseline(self):
  names=['restore_file','on_exit','rollback_config','clear_rollback','begin_install_snapshot','restore_install_snapshot','clear_install_snapshot','abort_install']
  traps='\n'.join(re.findall(r'^trap .* (?:EXIT|INT|TERM)$', SRC, re.M))
  self.run_case(names,r'''
mkdir -p "$RUN/system" "$RUN/geo"
printf BASELINE > "$XRAY_CONFIG"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf UNIT > "$RUN/system/xray.service"
systemctl() { case "$1" in show) printf 'ActiveState=inactive\n';; is-active) return 1;; esac; }; pgrep() { return 1; }
(
'''+traps+r'''
 begin_install_snapshot || exit 1
 outer=$INSTALL_ROLLBACK_DIR
 ROLLBACK_DIR="$RUN/inner"; mkdir "$ROLLBACK_DIR"
 printf INTERMEDIATE > "$ROLLBACK_DIR/config.json"
 printf CURRENT > "$XRAY_CONFIG"
 rm() { command rm "$@" || return 1; if [[ "$*" == *"$outer"* ]]; then builtin kill -TERM "$BASHPID"; fi; }
 abort_install
 exit 91
) && exit 81 || result=$?
[[ $result = 143 && $(< "$XRAY_CONFIG") = BASELINE ]]
''')
 def test_exit_recovery_failure_returns_nonzero(self):
  names=['on_exit','rollback_config','clear_rollback','restore_install_snapshot','clear_install_snapshot']
  traps='\n'.join(re.findall(r'^trap .* (?:EXIT|INT|TERM)$', SRC, re.M))
  for failure in ('stop','process','restore','restart'):
   with self.subTest(failure=failure):
    self.run_case(names,'FAILURE='+failure+'\n'+r'''
ROLLBACK_DIR="$RUN/pending"; mkdir "$ROLLBACK_DIR"
printf BASELINE > "$ROLLBACK_DIR/config.json"; touch "$ROLLBACK_DIR/was-active"
printf CURRENT > "$XRAY_CONFIG"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
systemctl() { [[ "$FAILURE" != stop ]]; }
stop_xray_processes() { [[ "$FAILURE" != process ]]; }
restore_file() { [[ "$FAILURE" != restore ]] && cp -p "$1" "$2"; }
restart_xray() { [[ "$FAILURE" != restart ]]; }
(
'''+traps+r'''
 exit 0
) && exit 81 || result=$?
[[ $result = 1 && -f "$ROLLBACK_DIR/config.json" ]]
''')
 def test_install_interrupt_restores_snapshot(self):
  names=['begin_install_snapshot','restore_install_snapshot','clear_install_snapshot','on_exit']
  traps='\n'.join(re.findall(r'^trap .* (?:EXIT|INT|TERM)$', SRC, re.M))
  for existing in (True,False):
   with self.subTest(existing=existing):
    self.run_case([n for n in names if n+'()' in SRC], 'EXISTING='+str(existing).lower()+'\n'+r'''
mkdir -p "$RUN/system" "$RUN/geo"
if "$EXISTING"; then printf OLD > "$XRAY_BIN"; printf OLD > "$XRAY_CONFIG"; printf OLDUNIT > "$RUN/system/xray.service"; fi
systemctl() { case "$1" in show) printf 'ActiveState=inactive\n';; is-active) return 1;; esac; }
pgrep() { return 1; }
(
'''+traps+r'''
 begin_install_snapshot || exit 1
 printf NEW > "$XRAY_BIN"; printf NEW > "$XRAY_CONFIG"; printf NEWUNIT > "$RUN/system/xray.service"
 builtin kill -INT "$BASHPID"
 exit 91
) && exit 81 || result=$?
[[ $result = 130 ]]
if "$EXISTING"; then
 [[ $(< "$XRAY_BIN") = OLD && $(< "$XRAY_CONFIG") = OLD && $(< "$RUN/system/xray.service") = OLDUNIT ]]
else
 [[ ! -e "$XRAY_BIN" && ! -e "$XRAY_CONFIG" && ! -e "$RUN/system/xray.service" ]]
fi
''')
 def test_modify_interrupt_restores_config_and_runtime(self):
  names=['write_config','rollback_config','clear_rollback','restore_install_snapshot','clear_install_snapshot','on_exit']
  # The same EXIT/INT/TERM declarations used by the real entrypoint.
  traps='\n'.join(re.findall(r'^trap .* (?:EXIT|INT|TERM)$', SRC, re.M))
  for active in (True,False):
   with self.subTest(active=active):
    self.run_case([n for n in names if n+'()' in SRC], 'ACTIVE='+str(active).lower()+'\n'+r'''
STATE=$ACTIVE
printf '{}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
validate_encryption_token() { :; }
service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
systemctl() {
 case "$1" in
 show) if "$STATE"; then printf 'ActiveState=active'; else printf 'ActiveState=inactive'; fi;;
 is-active) "$STATE";;
 stop) STATE=false; printf stop >> "$RUN/calls";;
 *) return 0;; esac
}
restart_xray() { printf restart >> "$RUN/calls"; STATE=true; }
pgrep() { return 1; }
(
'''+traps+r'''
 mv() { command mv "$@" || return 1; if [[ "${!#}" = "$XRAY_CONFIG" && ! -e signaled ]]; then touch signaled; builtin kill -TERM "$BASHPID"; fi; }
 write_config 443 uuid dec enc encryption || exit 1
 exit 91
) && exit 81 || result=$?
[[ $result = 143 && $(< "$XRAY_CONFIG") = '{}' && $(< "$ENCRYPTION_INFO") = enc ]]
'''+('grep -q restart "$RUN/calls"\n' if active else '! grep -q restart "$RUN/calls"\n'))
 def test_restore_uses_atomic_file_replacement(self):
  self.run_case(['rollback_config','clear_rollback'] + (['restore_file'] if 'restore_file()' in SRC else []),r'''
ROLLBACK_DIR="$RUN/pending"; mkdir "$ROLLBACK_DIR"
printf OLD > "$ROLLBACK_DIR/config.json"; chmod 604 "$ROLLBACK_DIR/config.json"; touch -t 202001010101 "$ROLLBACK_DIR/config.json"
printf NEW > "$XRAY_CONFIG"; ln "$XRAY_CONFIG" "$RUN/old-inode"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
rollback_config || exit 81
[[ $(< "$XRAY_CONFIG") = OLD && $(< "$RUN/old-inode") = NEW ]]
[[ $(stat -c '%a:%u:%g:%Y' "$XRAY_CONFIG") = $(stat -c '%a:%u:%g:%Y' "$RUN/old-inode") ]] && exit 82
[[ $(stat -c %a "$XRAY_CONFIG") = 604 ]]
''')
 def test_review_rollback_boundaries(self):
  names=['restore_install_snapshot','clear_install_snapshot','begin_install_snapshot','xray_pids','stop_xray_processes']
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system" "$RUN/geo"
printf OLD > "$INSTALL_ROLLBACK_DIR/xray"; printf OLDUNIT > "$INSTALL_ROLLBACK_DIR/xray.service"; printf NEW > "$XRAY_BIN"
pgrep() { [[ ! -e terminated ]] || return 1; printf 12; }; readlink() { printf '%s' "$XRAY_BIN"; }
kill() { touch terminated; }; systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }
restore_install_snapshot
[[ -e terminated && ! -e "$RUN/snapshot" && $(< "$XRAY_BIN") = OLD ]]
''')
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system" "$RUN/geo"
printf NEW > "$XRAY_BIN"; printf UNIT > "$RUN/system/xray.service"
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; else [[ "$1" != disable ]]; fi; }; pgrep() { return 1; }
if restore_install_snapshot; then exit 81; fi
[[ -e "$XRAY_BIN" && -e "$RUN/system/xray.service" && -d "$INSTALL_ROLLBACK_DIR" ]]
''')
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/geo"
systemctl() { case $1 in show) printf 'ActiveState=inactive\n';; stop) return 5;; is-active) return 1;; *) return 0;; esac; }; pgrep() { return 1; }
restore_install_snapshot
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
begin_install_snapshot
''')
 def test_install_failure_and_retry(self):
  names=['install_selected','begin_install_snapshot','restore_install_snapshot','clear_install_snapshot','abort_install','clear_rollback']
  for existing in (False,True):
   self.run_case(names,r'''
mkdir -p "$RUN/system" "$RUN/geo"
systemctl() { case "$1" in show) if [[ -f active ]]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi;; is-active) [[ -f active ]];; stop) rm -f active;; *) return 0;; esac; }
restart_xray() { touch active; }
run_official_installer() {
 if [[ "$1" = install ]]; then
  printf NEW > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
  mkdir -p "$RUN/system/xray.service.d" "$RUN/system/xray@.service.d"
  printf UNIT > "$RUN/system/xray.service"
  rm -f active
  return 0
 fi
 return 1
}
'''+('''printf OLD > "$XRAY_BIN"; chmod +x "$XRAY_BIN"; printf ORIGINAL > "$XRAY_CONFIG"; chmod 640 "$XRAY_CONFIG"; printf UNIT > "$RUN/system/xray.service"; touch active
''' if existing else '')+r'''
if install_selected 443 uuid encryption; then exit 81; fi
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
'''+('''[[ "$(<"$XRAY_BIN")" = OLD && "$(<"$XRAY_CONFIG")" = ORIGINAL && -f active ]]
[[ $(stat -c %a "$XRAY_CONFIG") = 640 ]]
''' if existing else '''[[ ! -e "$XRAY_BIN" && ! -e "$RUN/system/xray.service.d" ]]
if install_selected 443 uuid encryption; then exit 81; fi
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
'''))
 def test_update_rollback_leaves_unmodified_subscription_alone(self):
  names=['update_xray','begin_install_snapshot','restore_install_snapshot','clear_install_snapshot']
  for kind in ('directory','file','link'):
   with self.subTest(kind=kind):
    self.run_case(names,'KIND='+kind+'\n'+r'''
mkdir -p "$RUN/system" "$RUN/geo"; printf UNIT > "$RUN/system/xray.service"
printf OLD > "$XRAY_BIN"; chmod +x "$XRAY_BIN"; printf ORIGINAL > "$XRAY_CONFIG"
case "$KIND" in
 directory) mkdir "$SUBSCRIPTION_INFO"; printf KEEP > "$SUBSCRIPTION_INFO/unrelated" ;;
 file) printf KEEP > "$SUBSCRIPTION_INFO"; ln "$SUBSCRIPTION_INFO" "$RUN/same-inode" ;;
 link) printf KEEP > "$RUN/unrelated"; ln -s unrelated "$SUBSCRIPTION_INFO" ;;
esac
touch active
systemctl() {
 case "$1" in
 show) if [[ -f active ]]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi;;
 stop) rm -f active;;
 daemon-reload) :;;
 *) return 95;; esac
}
restart_xray() { [[ $(< "$XRAY_BIN") = OLD ]] && touch active restarted; }
run_official_installer() {
 case "$1" in
 install) printf NEW > "$XRAY_BIN";;
 install-geodata) touch geo_attempted; return 1;;
 *) return 95;; esac
}
if update_xray; then exit 81; fi
[[ -f geo_attempted && -f restarted && -f active && -z "$INSTALL_ROLLBACK_DIR" ]]
[[ $(< "$XRAY_BIN") = OLD && $(< "$XRAY_CONFIG") = ORIGINAL ]]
case "$KIND" in
 directory) [[ $(< "$SUBSCRIPTION_INFO/unrelated") = KEEP ]] ;;
 file) [[ "$SUBSCRIPTION_INFO" -ef "$RUN/same-inode" && $(< "$SUBSCRIPTION_INFO") = KEEP ]] ;;
 link) [[ $(readlink "$SUBSCRIPTION_INFO") = unrelated && $(< "$RUN/unrelated") = KEEP ]] ;;
esac
''')
 def test_install_rollback_restores_invalidated_subscription(self):
  names=['install_selected','begin_install_snapshot','restore_install_snapshot','clear_install_snapshot','abort_install','write_config','on_exit']
  setup=r'''
mkdir -p "$RUN/system" "$RUN/geo"; printf UNIT > "$RUN/system/xray.service"
printf '#!/bin/sh\nexit 0\n# old\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '{}' > "$XRAY_CONFIG"; printf ORIGINAL > "$SUBSCRIPTION_INFO"; chmod 600 "$SUBSCRIPTION_INFO"
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }
run_official_installer() { :; }; xray_supports() { :; }
generate_encryption_pair() { printf 'dec|enc'; }; validate_encryption_token() { :; }
service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
'''
  self.run_case(names,setup+r'''
restart_xray() {
 if [[ ! -e attempted ]]; then
  [[ ! -e "$SUBSCRIPTION_INFO" ]] || return 91
  touch attempted
  return 1
 fi
 touch restarted
}
if install_selected 443 uuid encryption; then exit 81; fi
[[ -f attempted && -f restarted && -z "$INSTALL_ROLLBACK_DIR" && -z "$ROLLBACK_DIR" ]]
[[ $(< "$SUBSCRIPTION_INFO") = ORIGINAL && $(stat -c %a "$SUBSCRIPTION_INFO") = 600 && $(< "$XRAY_CONFIG") = '{}' ]]
''')
  traps='\n'.join(re.findall(r'^trap .* (?:EXIT|INT|TERM)$', SRC, re.M))
  self.run_case(names,setup+r'''
restart_xray() { touch restarted; }
(
'''+traps+r'''
 rm() {
  command rm "$@" || return 1
  if [[ "$*" = "-f $SUBSCRIPTION_INFO" ]]; then
   touch invalidated
   builtin kill -TERM "$BASHPID"
  fi
 }
 install_selected 443 uuid encryption
 exit 91
) && exit 81 || status=$?
[[ $status = 143 && -f invalidated && -f restarted ]]
[[ $(< "$SUBSCRIPTION_INFO") = ORIGINAL && $(stat -c %a "$SUBSCRIPTION_INFO") = 600 && $(< "$XRAY_CONFIG") = '{}' ]]
if compgen -G "$RUN/snapshot-*" >/dev/null; then exit 82; fi
''')
 def test_stopped_update_rejects_incompatible_config(self):
  self.run_case(['update_xray','begin_install_snapshot','clear_install_snapshot'],r'''
mkdir -p "$RUN/system"; printf UNIT > "$RUN/system/xray.service"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf ORIGINAL > "$XRAY_CONFIG"
systemctl() { case "$1" in show) printf 'ActiveState=inactive\n';; is-active) return 1;; esac; }
run_official_installer() { printf '#!/bin/sh\nprintf "checked\\n" >> "%s"\nexit 1\n' "$RUN/parser-calls" > "$XRAY_BIN"; }
restore_install_snapshot() { touch restored; }
if update_xray; then exit 81; fi
[[ -f restored && -s "$RUN/parser-calls" && -d "$INSTALL_ROLLBACK_DIR" ]]
''')
 def test_update_preserves_stopped(self):
  self.run_case(['update_xray','begin_install_snapshot','clear_install_snapshot'],r'''
mkdir -p "$RUN/system" "$RUN/geo"; printf UNIT > "$RUN/system/xray.service"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '{}' > "$XRAY_CONFIG"
systemctl() { case "$1" in show) printf 'ActiveState=inactive\n';; is-active) return 1;; esac; }
run_official_installer() { printf '# updated\n' >> "$XRAY_BIN"; }
restart_xray() { exit 81; }
update_xray
[[ $(tail -n 1 "$XRAY_BIN") = '# updated' && -z "$INSTALL_ROLLBACK_DIR" ]]
''')
 def test_stop_failure_retains_recovery(self):
  self.run_case(['restore_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"
printf ORIGINAL > "$INSTALL_ROLLBACK_DIR/config.json"; printf NEW > "$XRAY_CONFIG"
mkdir -p "$RUN/system"; printf UNIT > "$RUN/system/xray.service"
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; else return 1; fi; }
if restore_install_snapshot; then exit 81; fi
[[ "$(<"$XRAY_CONFIG")" = NEW && -f "$INSTALL_ROLLBACK_DIR/config.json" ]]
''')
 def test_failed_restart_checks_residual_processes_before_restore(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"users":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }; current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }
write_config() { :; }; restart_xray() { return 1; }
stop_xray_processes() { touch inspected; return 1; }
rollback_config() { touch wrongly-restored; }
modify_config || true
[[ -f inspected && ! -e wrongly-restored ]]
''')
 def test_failed_restore_does_not_restart_partial_config(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
write_config() { :; }
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }
restart_xray() { if [[ -e restarted ]]; then touch BAD_SECOND_RESTART; fi; touch restarted; return 1; }
stop_xray_processes() { :; }
rollback_config() { touch restore-attempted; return 1; }
modify_config || true
[[ -f restore-attempted && ! -e BAD_SECOND_RESTART ]]
''')
 def test_process_identity_and_failure(self):
  self.run_case(['xray_pids','stop_xray_processes'],r'''
pgrep() { [[ ! -f stopped ]] || return 1; printf '12\n13\n'; }
readlink() { case "$1" in */12/exe) printf '%s (deleted)' "$XRAY_BIN";; *) printf /other;; esac; }
kill() { [[ "$*" = '-TERM 12' ]] || exit 81; touch stopped; }
stop_xray_processes
[[ -f stopped ]]
pgrep() { return 2; }
if stop_xray_processes; then exit 82; fi
''')
 def test_uninstall_query_failure_keeps_files(self):
  self.run_case(['uninstall_xray','has_xray_residue','xray_pids','stop_xray_processes'],r'''
printf ORIGINAL > "$XRAY_CONFIG"
read() { confirm=y; }; systemctl() { return 1; }; pgrep() { return 2; }
if uninstall_xray; then exit 81; fi
[[ "$(<"$XRAY_CONFIG")" = ORIGINAL ]]
''')
 def test_stable_and_changed_pid(self):
  self.run_case(['restart_xray','xray_main_pid'],r'''
systemctl() { if [[ "$1" = show ]]; then if [[ -e changed ]]; then printf 'MainPID=13'; else printf 'MainPID=12'; fi; fi; }
readlink() { printf '%s' "$XRAY_BIN"; }
sleep() { :; }
restart_xray
sleep() { touch changed; }
if restart_xray; then exit 81; fi
''')
 def test_port_fallback(self):
  self.run_case(['port_in_use','check_port'],r'''
ss() { return 2; }; netstat() { return 0; }
check_port 443
netstat() { printf 'tcp 0 0 :::443 :::* LISTEN\n'; }
if check_port 443; then exit 81; fi
ss() { return 0; }
check_port 443
''')
 def test_recovery_blocks_new_snapshot(self):
  self.run_case(['begin_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"
printf ORIGINAL > "$INSTALL_ROLLBACK_DIR/config.json"
if begin_install_snapshot; then exit 81; fi
[[ "$INSTALL_ROLLBACK_DIR" = "$RUN/pending" ]]
''')
 def test_dependency_installs_process_tools(self):
  o=self.run_case(['require_root_and_dependencies'],r'''
id() { printf 0; }
command() { if [[ "$*" = '-v pgrep' && ! -e ready ]]; then return 1; fi; builtin command "$@"; }
apt-get() { printf '%s\n' "$*"; touch ready; }
require_root_and_dependencies
[[ -f ready ]]
''')
  self.assertIn('procps',o.stdout)
 def test_noninteractive_no_args_never_installs_dependencies(self):
  self.run_case(['main'],r'''
require_root_and_dependencies() { touch dependencies; }
main_menu() { touch menu; }
if (main) < /dev/null; then exit 81; else [[ $? = 2 ]]; fi
[[ ! -e dependencies && ! -e menu ]]
''')
 def test_service_query_failure_does_not_commit_or_clean_up(self):
  self.run_case(['write_config','begin_install_snapshot','restore_install_snapshot'],r'''
validate_encryption_token() { :; }; service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '{}' > "$XRAY_CONFIG"; printf ORIGINAL > "$SUBSCRIPTION_INFO"
systemctl() {
 case "$1" in show) printf 'ActiveState=inactive\n'; return 17;; is-active) return 17;; *) touch mutated;; esac
}
if write_config 443 uuid dec enc encryption; then exit 81; fi
[[ $(< "$XRAY_CONFIG") = '{}' && $(< "$SUBSCRIPTION_INFO") = ORIGINAL && -z "$ROLLBACK_DIR" ]]
if begin_install_snapshot; then exit 82; fi
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir "$INSTALL_ROLLBACK_DIR"
if restore_install_snapshot; then exit 83; fi
[[ -e "$XRAY_BIN" && -d "$INSTALL_ROLLBACK_DIR" && ! -e mutated ]]
''')
 def test_dependency_failure_stops_before_continuing(self):
  self.run_case(['require_root_and_dependencies'],r'''
id() { printf 0; }
systemctl() { printf 'Version=252\n'; }
command() { if [[ "$*" = '-v pgrep' && ! -e ready ]]; then return 1; fi; builtin command "$@"; }
apt-get() { if [[ "${!#}" = update ]]; then return 0; fi; touch ready; return 17; }
if (require_root_and_dependencies || return $?); then exit 81; fi
[[ -e ready ]]
''')
 def test_official_unit_write_failure_is_fatal(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['normalize_official_writes'],r'''
cp "$PINNED_INSTALLER" official
normalize_official_writes official
awk '/^install_startup_service_file\(\)/ {inside=1} inside {print} inside && /^}/ {exit}' official > unit.sh
# Keep the fixed literal anchors intact until after normalization.
python3 -c 'from pathlib import Path; p=Path("unit.sh"); p.write_text(p.read_text().replace("/etc/systemd/system", "system"))'
cat >> unit.sh <<'SHELL'
INSTALL_USER_UID=0; INSTALL_USER=root; JSONS_PATH=''; JSON_PATH=config
systemctl() { touch daemon-reload; }
systemd_cat_config() { :; }
install_startup_service_file
touch completed
SHELL
mkdir system
command bash unit.sh
[[ -f completed && -f daemon-reload && -s system/xray.service && -s system/xray@.service ]]
rm completed daemon-reload system/xray@.service
mkdir system/xray@.service
if command bash unit.sh; then exit 81; fi
[[ ! -e completed && ! -e daemon-reload ]]
''')
 def test_failed_rollback_restart_keeps_config_snapshot(self):
  self.run_case(['modify_config','rollback_config','clear_rollback','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"users":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }; current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=active\n'; fi; }; stop_xray_processes() { :; }
write_config() {
 ROLLBACK_DIR="$RUN/pending"; mkdir "$ROLLBACK_DIR"
 cp "$XRAY_CONFIG" "$ROLLBACK_DIR/config.json"; cp "$ENCRYPTION_INFO" "$ROLLBACK_DIR/encryption.info"
 printf NEW > "$XRAY_CONFIG"
}
restart_xray() { printf 'restart\n' >> restarts; return 1; }
modify_config || true
[[ $(wc -l < restarts) = 2 && $(< "$XRAY_CONFIG") != NEW ]]
[[ "$ROLLBACK_DIR" = "$RUN/pending" && -f "$ROLLBACK_DIR/config.json" && "$RECOVERY_PENDING" = true ]]
''')
 def test_config_change_invalidates_old_link_and_rollback_restores_it(self):
  self.run_case(['write_config','rollback_config','clear_rollback'],r'''
validate_encryption_token() { :; }; service_account() { id -u | tr '\n' ':'; id -g; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '{}' > "$XRAY_CONFIG"; printf ORIGINAL > "$SUBSCRIPTION_INFO"
write_config 443 uuid dec enc encryption || exit 82
[[ ! -e "$SUBSCRIPTION_INFO" ]]
rollback_config || exit 83
[[ $(< "$XRAY_CONFIG") = '{}' && $(< "$SUBSCRIPTION_INFO") = ORIGINAL ]]
''')
 def test_config_write_never_moves_client_info_into_directory(self):
  self.run_case(['write_config','rollback_config','clear_rollback'],r'''
validate_encryption_token() { :; }; service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '{}' > "$XRAY_CONFIG"; printf ORIGINAL > "$SUBSCRIPTION_INFO"
mkdir "$ENCRYPTION_INFO"
if write_config 443 uuid dec enc encryption; then exit 81; fi
[[ $(< "$XRAY_CONFIG") = '{}' && $(< "$SUBSCRIPTION_INFO") = ORIGINAL ]]
[[ -z $(find "$ENCRYPTION_INFO" -mindepth 1) ]]
''')
 def test_subscription_rejects_unsupported_profile(self):
  self.run_case(['show_subscription','valid_port','valid_uuid','uri_encode'],r'''
printf '%s' '{"inbounds":[{"protocol":"vless","port":443,"settings":{"users":[{"id":"00000000-0000-4000-8000-000000000000","flow":"xtls-rprx-vision"}],"decryption":"old"},"streamSettings":{"method":"raw","security":"none"}}]}' > "$XRAY_CONFIG"
cp "$XRAY_CONFIG" valid.json
printf enc > "$ENCRYPTION_INFO"
validate_encryption_token() { :; }; public_ip() { printf 192.0.2.1; }
show_subscription || exit 82
cp "$SUBSCRIPTION_INFO" original
for change in '.inbounds[0].streamSettings.security="tls"' '.inbounds[0].streamSettings.method="ws"' '.inbounds[0].settings.users[0].flow=""' '.inbounds[0].protocol="trojan"' '., .' ; do
 jq "$change" valid.json > "$XRAY_CONFIG"
 if show_subscription; then exit 81; fi
 cmp original "$SUBSCRIPTION_INFO"
done
''')
 def test_parser_rejects_trailing_separators_and_extra_lines(self):
  self.run_case(['valid_ipv6','valid_appearance','validate_encryption_token'],r'''
valid_ipv6 '::ffff:192.0.2.1'
if valid_ipv6 '::ffff:192.0.2.1.'; then exit 81; fi
key=mlkem768x25519plus.native.0rtt.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
validate_encryption_token "$key" 0rtt
if validate_encryption_token "$key." 0rtt; then exit 82; fi
if validate_encryption_token "$key"$'\nextra' 0rtt; then exit 83; fi
''')
 def test_menu_keeps_recovery_reference(self):
  self.run_case(['main_menu'],r'''
print_header() { :; }; menu_item() { :; }
read() { if [[ "$*" = *choice ]]; then if [[ ! -e entered ]]; then choice=1; touch entered; else choice=0; fi; fi; }
interactive_install() { INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"; return 1; }
main_menu
[[ "$INSTALL_ROLLBACK_DIR" = "$RUN/pending" ]]
''')
 def test_menu_pending_recovery_allows_only_diagnostics(self):
  self.run_case(['main_menu'],r'''
print_header() { :; }; menu_item() { :; }
step=0; RECOVERY_PENDING=false
read() {
 if [[ "${!#}" = choice ]]; then
  local -a choices=(6 1 2 3 4 6 7 5 0)
  choice=${choices[step]}; step=$((step+1))
 fi
}
interactive_install() { touch unsafe; }; current_xray_version() { touch unsafe; }
latest_xray_version() { :; }; restart_xray() { touch unsafe; }; uninstall_xray() { touch unsafe; }
show_subscription() { touch unsafe; }; journalctl() { touch diagnostic; }
modify_config() {
 if [[ -n "$ROLLBACK_DIR" ]]; then touch unsafe; fi
 ROLLBACK_DIR="$RUN/pending"; RECOVERY_PENDING=true; return 1
}
main_menu
[[ ! -e unsafe && -e diagnostic && "$ROLLBACK_DIR" = "$RUN/pending" ]]
''')
 def test_config_write_preserves_existing_directory_permissions(self):
  self.run_case(['write_config','clear_rollback'],r'''
validate_encryption_token() { :; }; service_account() { printf '%s:%s' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
mkdir -m 750 "$RUN/config-dir"; XRAY_CONFIG="$RUN/config-dir/config.json"
write_config 443 uuid dec enc encryption || exit 82
[[ $(stat -c %a "$RUN/config-dir") = 750 && $(stat -c %a "$XRAY_CONFIG") = 600 ]]
clear_rollback
''')
 def test_awk_parser_has_no_warning(self):
  o=self.run_case(['extract_vlessenc_value'],'''value=$(extract_vlessenc_value $'Authentication: X\\n"encryption": "test"' 'Authentication: X' encryption)
[[ "$value" = test ]]''')
  self.assertEqual(o.stderr,'')
 def test_config_recovery_blocks_new_write(self):
  self.run_case(['write_config'],r'''
ROLLBACK_DIR="$RUN/pending"; mkdir -p "$ROLLBACK_DIR"
validate_encryption_token() { :; }; service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
if write_config 443 uuid dec enc encryption; then exit 81; fi
[[ "$ROLLBACK_DIR" = "$RUN/pending" && ! -e "$XRAY_CONFIG" ]]
''')
 def test_restart_requires_real_stable_process(self):
  self.run_case(['restart_xray'] + (['xray_main_pid'] if 'xray_main_pid()' in SRC else []),r'''
systemctl() { if [[ "$1" = show ]]; then printf '0\n'; else return 0; fi; }
if restart_xray; then exit 81; fi
''')
 def test_dropin_only_uninstall(self):
  self.run_case(['uninstall_xray'] + [n for n in ('xray_pids','stop_xray_processes','has_xray_residue') if n+'()' in SRC],r'''
mkdir -p "$RUN/system/xray.service.d"
printf OLD > "$RUN/system/xray.service.d/custom.conf"
read() { confirm=y; }
systemctl() { case "$1" in is-active|is-enabled) return 1;; *) return 0;; esac; }
pgrep() { return 1; }
run_official_installer() { exit 81; }
uninstall_xray
[[ ! -d "$RUN/system/xray.service.d" ]]
''')
 def test_fresh_rollback_removes_generated_dropins(self):
  self.run_case(['restore_install_snapshot','clear_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system/xray.service.d" "$RUN/system/xray@.service.d" "$RUN/geo"
printf NEW > "$RUN/system/xray.service.d/10.conf"
systemctl() { if [[ "$1" = show ]]; then printf 'ActiveState=inactive\n'; fi; }
restore_install_snapshot
[[ ! -e "$RUN/system/xray.service.d" && ! -e "$RUN/system/xray@.service.d" ]]
''')
 def test_ipv6_subscription_rejects_ipv4_only_listener(self):
  self.run_case(['show_subscription','valid_port','valid_uuid','uri_encode'],r'''
printf '%s' '{"inbounds":[{"protocol":"vless","listen":"0.0.0.0","port":443,"settings":{"users":[{"id":"00000000-0000-4000-8000-000000000000","flow":"xtls-rprx-vision"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"; printf ORIGINAL > "$SUBSCRIPTION_INFO"
validate_encryption_token() { :; }
public_ip() { printf '[2001:db8::7]'; }
if show_subscription; then exit 81; fi
[[ $(< "$SUBSCRIPTION_INFO") = ORIGINAL ]]
''')
 def test_invalid_subscription_rejected(self):
  o=self.run_case(['show_subscription','validate_encryption_token','valid_appearance','valid_port','valid_uuid','uri_encode'],r'''
printf '%s' '{"inbounds":[{"protocol":"vless","port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000","flow":"xtls-rprx-vision"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf INVALID > "$ENCRYPTION_INFO"
public_ip() { printf 192.0.2.1; }
if show_subscription; then exit 81; fi
[[ ! -e "$SUBSCRIPTION_INFO" ]]
''')
  self.assertIn('客户端加密信息或配置参数无效',o.stderr)
 def test_target_sync(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; validate_reality_key() { :; }; valid_sni() { :; }; valid_short_id() { :; }
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s' '{"inbounds":[{"settings":{"clients":[{"id":"old"}]},"streamSettings":{"security":"reality","realitySettings":{"target":"old.example:443","dest":"old.example:443","serverNames":["old.example"]}}}]}' > "$XRAY_CONFIG"
write_config 443 uuid dec enc reality private public new.example 20220701 true
jq -e '.inbounds[0].streamSettings.realitySettings | (.target // .dest)=="new.example:443"' "$XRAY_CONFIG"
''')
 def test_port_query_failure(self):
  self.run_case(['port_in_use'],'''ss() { return 77; }; netstat() { return 77; }
if port_in_use 443; then exit 81; else [[ $? = 2 ]]; fi''')
 def test_ipv6(self):
  self.run_case(['valid_ipv6'],'''for ip in '1::2:' ':1::2'; do if valid_ipv6 "$ip"; then exit 81; fi; done
for ip in '::' '::1' '2001:db8::' '::ffff:192.0.2.1'; do valid_ipv6 "$ip" || exit 82; done''')
if __name__=='__main__':unittest.main(verbosity=2)
