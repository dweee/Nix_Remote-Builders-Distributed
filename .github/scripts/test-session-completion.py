"""Run the actual reaper shell with a delayed fake GitHub publication."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT/'src/nix-remote.nu').read_text()
REAPER = SOURCE.split('def reap-run ',1)[1].split("    let script = '\n",1)[1].split("\n        exit 1'",1)[0]+'\nexit 1'


class SessionCompletion(unittest.TestCase):
    def test_cold_publication_window_and_required_provider_conclusion(self):
        for budget, conclusion, cancelled, success in [(600,'success',True,True),
                (3600,'success',False,True),(3600,'failure',False,False)]:
            with self.subTest(budget=budget,conclusion=conclusion),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);bin=root/'bin';bin.mkdir()
                (bin/'sleep').write_text('#!/bin/sh\nexit 0\n')
                (bin/'gh').write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE']);args=sys.argv[1:]
if args[:2]==['run','list']:
 p=root/'polls';n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
 if '.status != ' in args[-1] or n>=100:print('123')
elif args[:2]==['run','cancel']:(root/'cancelled').touch()
elif args[:2]==['run','view']:
 if '--json' in args:print(json.dumps({'databaseId':123,'headSha':'a'*40,'status':'completed','conclusion':os.environ['CONCLUSION'],'displayTitle':'nix-remote [babc123]'}))
 else:print('builder publication log')
elif args[:2]==['api','-X']:
 assert (root/'logs/babc123.json').exists()
 (root/'deleted').touch()
else:sys.exit(2)
''')
                for command in bin.iterdir():command.chmod(0o755)
                env={**os.environ,'PATH':str(bin)+os.pathsep+os.environ['PATH'],'FIXTURE':str(root),'CONCLUSION':conclusion}
                result=subprocess.run(['bash','-c',REAPER,'_','fixture/builders','babc123',str(root/'logs'),
                    'true',str(budget),'true'],env=env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode==0,success,result.stderr)
                self.assertEqual((root/'cancelled').exists(),cancelled)
                metadata=json.loads((root/'logs/babc123.json').read_text())
                self.assertEqual(metadata['conclusion'],conclusion)
                self.assertEqual(metadata['headSha'],'a'*40)
                self.assertTrue((root/'deleted').exists())


if __name__=='__main__':unittest.main()
