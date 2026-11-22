"""Offline checks of the exact opt-in workflow helper; never contact a runner."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
WORKFLOW=(ROOT/'.github/workflows/nix-builder.yml').read_text()
SOURCE=textwrap.dedent(WORKFLOW.split("<<'PYTHON'\n",1)[1].split('\n          PYTHON\n',1)[0])
HELPER=types.ModuleType('userspace_fixture');exec(compile(SOURCE,'userspace_fixture','exec'),HELPER.__dict__)


class UserspaceCandidate(unittest.TestCase):
    def test_opt_in_does_not_change_native_default_or_credentials(self):
        self.assertEqual(WORKFLOW.count('experimental_darwin_userspace:\n'),2)
        for part in WORKFLOW.split('experimental_darwin_userspace:\n')[1:]:
            self.assertIn('default: false',part.split('timeout_startup:',1)[0])
        userspace=WORKFLOW.split('- name: "Connect opt-in Darwin userspace',1)[1].split('- name:',1)[0]
        self.assertIn("if: runner.os == 'macOS' && inputs.experimental_darwin_userspace",userspace)
        self.assertIn('tailscale/github-action@064b10558093f38325e838ddea35486bdc6b1d5c',userspace)
        for setting in ['version: "1.104.4"','--tun=userspace-networking','--ssh --accept-dns=false',
                        'tags: ${{ inputs.tailscale_tags }}','${{ secrets.TS_OAUTH_CLIENT_ID }}']:
            self.assertIn(setting,userspace)
        self.assertIn('if: always() && runner.os == \'macOS\' && inputs.experimental_darwin_userspace',WORKFLOW)
        # No change to the independently pinned helper checkout/admission.
        self.assertIn('ref: 886d11b4b7c096383adfb60fc5daaa2e4cbe2074',WORKFLOW)
        self.assertIn('"$DIAG_SAMPLES" -lt 121',WORKFLOW)
        self.assertIn('DIAG_NEXT=$((SECONDS + 60))',WORKFLOW)

    def exercise_dns(self,dns,search,expected):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'dns.json'
            with patch.object(HELPER,'command',side_effect=[dns,search]),patch.object(HELPER,'public_dns'),redirect_stdout(io.StringIO()):
                HELPER.dns('save',path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
            with patch.object(HELPER,'command',return_value='') as command,patch.object(HELPER,'public_dns') as resolve,redirect_stdout(io.StringIO()) as output:
                HELPER.dns('restore',path)
            self.assertEqual([c.args[0] for c in command.call_args_list],expected)
            resolve.assert_called_once()
            self.assertEqual(json.loads(output.getvalue()),{'kind':'userspace-dns','restored':True,'publicDns':True})
            self.assertNotIn('private.example',output.getvalue())

    def test_dhcp_dns_and_empty_search_are_restored(self):
        self.exercise_dns("There aren't any DNS Servers set on Ethernet.","There aren't any Search Domains set on Ethernet.",
                          [['sudo','/usr/sbin/networksetup','-setdnsservers','Ethernet','Empty'],
                           ['sudo','/usr/sbin/networksetup','-setsearchdomains','Ethernet','Empty']])

    def test_explicit_original_dns_and_search_are_restored(self):
        self.exercise_dns('192.0.2.53\n2001:db8::53','private.example',
                          [['sudo','/usr/sbin/networksetup','-setdnsservers','Ethernet','192.0.2.53','2001:db8::53'],
                           ['sudo','/usr/sbin/networksetup','-setsearchdomains','Ethernet','private.example']])

    def test_bad_or_preexisting_tailnet_resolver_aborts(self):
        for text in ['', '100.100.100.100', '-setdnsservers', 'private.example']:
            with self.subTest(text=text),self.assertRaises((RuntimeError,ValueError)):
                HELPER.dns_values(text,'dns')

    def test_snapshot_symlink_and_public_mode_are_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            target=Path(temporary)/'target';target.write_text('{"dns":[],"search":[]}');target.chmod(0o644)
            link=Path(temporary)/'link';link.symlink_to(target)
            for path in [target,link]:
                with self.subTest(path=path.name),patch.object(HELPER,'command') as command,self.assertRaises((RuntimeError,OSError)):
                    HELPER.dns('restore',path)
                command.assert_not_called()

    def test_health_output_is_fixed_self_booleans_and_numeric_counters_only(self):
        answers=[json.dumps({'BackendState':'Running','Self':{'Online':True,'HostName':'private-host','TailscaleIPs':['100.1.2.3']},
                             'Peer':{'secret':{'DNSName':'private.example'}}}), '123','10000','32768',
                 'private.example 100.1.2.3\n7 requests for memory denied\n8 requests for memory delayed\n9 calls to protocol drain routines']
        with patch.object(HELPER,'command',side_effect=answers),redirect_stdout(io.StringIO()) as output:
            HELPER.sample()
        value=json.loads(output.getvalue())
        self.assertEqual(value['mbufDenied'],7)
        self.assertTrue(value['running']);self.assertTrue(value['selfOnline'])
        self.assertNotIn('private',output.getvalue());self.assertNotIn('100.1.2.3',output.getvalue())
        self.assertTrue(all(isinstance(v,(bool,int)) for k,v in value.items() if k!='kind'))

    def test_missing_diagnostics_are_nonfatal_and_do_not_print_child_errors(self):
        with patch.object(HELPER,'command',side_effect=RuntimeError('private-host token')),redirect_stdout(io.StringIO()) as output:
            HELPER.sample()
        self.assertFalse(json.loads(output.getvalue())['statusAvailable'])
        self.assertNotIn('private',output.getvalue())


if __name__=='__main__':unittest.main()
