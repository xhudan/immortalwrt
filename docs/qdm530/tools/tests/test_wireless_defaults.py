#!/usr/bin/env python3
"""Run the real preinit/seeding functions with temporary files and a fake UCI.
No router access, real UCI invocation, or wireless reload.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
BASE = ROOT / 'target/linux/qualcommax/ipq50xx/base-files'
PREINIT = (BASE / 'lib/preinit/83_qdm530_wireless_defaults').read_text()
HOTPLUG = (BASE / 'etc/hotplug.d/ieee80211/13-qdm530-5ghz-channel').read_text()
FUNCTIONS = HOTPLUG[HOTPLUG.index('seed_5g()'):HOTPLUG.index('\nconfig_load wireless')]
STUB = r'''
config_get() { case "$1" in band) band="$BAND";; dev) dev=radio0;; esac; }
uci() {
 case "$2" in
 get) case "$3" in
 wireless.primary.macaddr) [ "$EXISTING" = 1 ] && echo 02:11:22:33:44:51;;
 *.band) echo "$BAND";;
 *.country) [ -n "$COUNTRY" ] && echo "$COUNTRY";;
 esac;;
 set) echo "SET $3";;
 esac
}
macaddr_add() { echo 02:11:22:33:44:51; }
'''

class Defaults(unittest.TestCase):
    def run_case(self, existing_config, band='5g', existing_mac='1', seeded=False):
        with tempfile.TemporaryDirectory(prefix='qdm530-test-') as tmp:
            root = Path(tmp)
            (root / 'etc/config').mkdir(parents=True)
            (root / 'tmp/sysinfo').mkdir(parents=True)
            (root / 'tmp/sysinfo/board_name').write_text('unbranded,qdm530\n')
            if existing_config:
                # Deliberately no country: this is still operator-owned config.
                (root / 'etc/config/wireless').write_text("config wifi-device 'radio0'\n option channel '149'\n option htmode 'HE80'\n")
            if seeded:
                (root / 'etc/qdm530-5ghz-seeded').touch()
            def paths(text):
                return text.replace('/etc/', str(root / 'etc') + '/').replace('/tmp/sysinfo/', str(root / 'tmp/sysinfo') + '/')
            script = 'boot_hook_add() { :; }\n' + paths(PREINIT) + '\nqdm530_wireless_defaults\n'
            script += STUB + '\n' + paths(FUNCTIONS)
            script += '\nlan_base() { echo 02:11:22:33:44:50; }\n'
            script += 'changed=0; seeded_5g=0; did_2g=; did_5g=\n'
            script += f'SEEDED="{root}/etc/qdm530-5ghz-seeded"\n'
            script += 'seed_5g radio0\nseed_iface_mac primary\nseed_iface_mac guest\n'
            script += 'echo "SEEDED5=$seeded_5g"\n'
            result = subprocess.run(['sh', '-c', script], env={**os.environ, 'BAND': band, 'COUNTRY': '', 'EXISTING': existing_mac}, text=True, capture_output=True, check=True)
            return result.stdout, (root / 'etc/qdm530-5ghz-pending').exists()

    def test_preserved_config_without_country(self):
        out, pending = self.run_case(True)
        self.assertNotIn('SET ', out)
        self.assertFalse(pending)

    def test_fresh_config_gets_board_defaults(self):
        out, pending = self.run_case(False, existing_mac='')
        self.assertIn('channel=36', out)
        self.assertIn('htmode=HE160', out)
        self.assertIn('country=CN', out)
        self.assertIn('SEEDED5=1', out)
        self.assertNotIn('wireless.guest.macaddr', out)
        self.assertTrue(pending)

    def test_late_5g_keeps_pending_token(self):
        out, pending = self.run_case(False, band='2g', existing_mac='')
        self.assertIn('SEEDED5=0', out)
        self.assertTrue(pending)

    def test_existing_marker_is_respected(self):
        out, pending = self.run_case(True, seeded=True)
        self.assertNotIn('SET ', out)
        self.assertFalse(pending)

    def test_seeded_primary_does_not_assign_guest(self):
        out, _ = self.run_case(True, band='2g')
        self.assertNotIn('wireless.guest.macaddr', out)

if __name__ == '__main__':
    unittest.main()
