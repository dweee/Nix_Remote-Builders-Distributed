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

FAKE_GH = '''#!/usr/bin/env python3
import json,os,re,sys
from pathlib import Path
root=Path(os.environ['FIXTURE']);args=sys.argv[1:]
with (root/'commands').open('a') as output:output.write(json.dumps(args)+'\\n')
if args[:2]==['run','list']:
 p=root/'polls';n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n))
 if '.status != ' in args[-1] or n>=int(os.environ.get('COMPLETE_AFTER','1')):print('123')
elif args[:2]==['run','cancel']:
 record=json.loads((root/'logs/babc123.cancel').read_text())
 assert record['run']==123 and record['reason']=='completion-window'
 (root/'cancelled').touch()
elif args[:2]==['run','view']:
 if '--json' in args:print(json.dumps({'databaseId':123,'headSha':'a'*40,'status':'completed',
  'conclusion':os.environ['CONCLUSION'],'displayTitle':'nix-remote [babc123]','attempt':2,
  'createdAt':'2026-01-01T00:00:00Z','startedAt':'2026-01-01T00:01:00Z','updatedAt':'2026-01-01T00:02:00Z'}))
 else:print('builder publication log')
elif args[:2]==['api','-X']:
 metadata=json.loads((root/'logs/babc123.json').read_text())
 assert metadata['databaseId']==123 and 'jobs' in metadata
 assert 'annotations' in metadata['diagnostics']
 (root/'deleted').touch()
elif args==['api','repos/fixture/builders/actions/runs/123/attempts/2/jobs?per_page=100']:
 if os.environ.get('JOBS_UNAVAILABLE'):sys.exit(1)
 count=int(os.environ.get('JOB_COUNT','1'))
 print(json.dumps({'total_count':count,'jobs':[{'id':1001+i,'name':'darwin-0','status':'completed',
  'check_run_url':os.environ.get('CHECK_URL',f'https://api.github.com/repos/fixture/builders/check-runs/{7001+i}'),
  'conclusion':os.environ['CONCLUSION'],'steps':[
   {'number':1,'name':'Watchdog','status':'completed','conclusion':os.environ['CONCLUSION']}]} for i in range(count)]}))
elif len(args)==2 and args[0]=='api' and re.fullmatch(r'repos/fixture/builders/check-runs/70[0-9][0-9]/annotations\\?per_page=100',args[1]):
 if os.environ.get('ANNOTATIONS_UNAVAILABLE'):sys.exit(1)
 print(json.dumps([{'annotation_level':'failure','title':'Cancelled',
  'message':os.environ.get('ANNOTATION_MESSAGE','The run was canceled by @fixture.'),
  'raw_details':'excluded-raw-details','path':'excluded-private-path'}]*int(os.environ.get('ANNOTATION_COUNT','1'))))
else:sys.exit('unexpected fake gh call: '+str(args))
'''


class SessionCompletion(unittest.TestCase):
    def reap(self, root, budget=3600, conclusion='cancelled', **variables):
        bin=root/'bin';bin.mkdir()
        (bin/'sleep').write_text('#!/bin/sh\nexit 0\n')
        (bin/'gh').write_text(FAKE_GH)
        for command in bin.iterdir():command.chmod(0o755)
        env={**os.environ,'PATH':str(bin)+os.pathsep+os.environ['PATH'],
             'FIXTURE':str(root),'CONCLUSION':conclusion,**variables}
        result=subprocess.run(['bash','-c',REAPER,'_','fixture/builders','babc123',str(root/'logs'),
            'true',str(budget),'true'],env=env,capture_output=True,text=True,timeout=20)
        metadata=json.loads((root/'logs/babc123.json').read_text())
        self.assertTrue((root/'deleted').exists(),result.stderr)
        self.assertEqual((root/'logs').stat().st_mode & 0o777,0o700)
        self.assertEqual((root/'logs/babc123.json').stat().st_mode & 0o777,0o600)
        self.assertEqual(sorted(p.name for p in (root/'logs').iterdir()),['babc123.json','babc123.log'])
        self.assertNotIn('excluded-',json.dumps(metadata))
        return result,metadata

    def test_cold_publication_window_and_required_provider_conclusion(self):
        for budget, conclusion, cancelled, success in [(600,'success',True,True),
                (3600,'success',False,True),(3600,'failure',False,False),
                (3600,'cancelled',False,False)]:
            with self.subTest(budget=budget,conclusion=conclusion),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                result,metadata=self.reap(root,budget,conclusion,COMPLETE_AFTER='100')
                self.assertEqual(result.returncode==0,success,result.stderr)
                self.assertEqual((root/'cancelled').exists(),cancelled)
                self.assertEqual(metadata['conclusion'],conclusion)
                self.assertEqual(metadata['headSha'],'a'*40)
                self.assertEqual(metadata['attempt'],2)
                self.assertEqual(metadata['jobs'][0]['databaseId'],1001)
                self.assertEqual(metadata['jobs'][0]['steps'][0]['conclusion'],conclusion)
                self.assertRegex(metadata['reapedAt'],r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
                if cancelled:
                    self.assertEqual(metadata['localCancel']['by'],'nix-remote-reaper')
                    self.assertEqual(metadata['localCancel']['reason'],'completion-window')
                    self.assertEqual(metadata['localCancel']['run'],123)
                    self.assertRegex(metadata['localCancel']['at'],r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
                else:self.assertIsNone(metadata['localCancel'])
                annotations=metadata['diagnostics']['annotations']
                if conclusion=='success':
                    self.assertEqual(annotations,[])
                    self.assertNotIn('/annotations?',(root/'commands').read_text())
                else:
                    self.assertEqual(annotations[0]['job'],1001)
                    self.assertEqual(annotations[0]['checkRunId'],7001)
                    self.assertEqual(annotations[0]['entries'][0]['message'],'The run was canceled by @fixture.')

    def test_unavailable_diagnostics_do_not_block_deletion_or_mask_conclusion(self):
        for variable in ['JOBS_UNAVAILABLE','ANNOTATIONS_UNAVAILABLE']:
            for conclusion in ['success','cancelled']:
                with self.subTest(variable=variable,conclusion=conclusion),tempfile.TemporaryDirectory() as temporary:
                    result,metadata=self.reap(Path(temporary),conclusion=conclusion,**{variable:'1'})
                    self.assertEqual(result.returncode==0,conclusion=='success',result.stderr)
                    if variable=='JOBS_UNAVAILABLE':
                        self.assertEqual(metadata['diagnostics']['jobsStatus'],'unavailable')
                    elif conclusion!='success':
                        self.assertEqual(metadata['diagnostics']['annotations'][0]['status'],'unavailable')

    def test_annotations_are_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            result,metadata=self.reap(Path(temporary),ANNOTATION_MESSAGE='x'*2000)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(metadata['diagnostics']['annotations'][0]['entries'][0]['message'],'x'*1000)

    def test_request_and_record_counts_are_bounded_and_truncation_is_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            result,metadata=self.reap(root,JOB_COUNT='101',ANNOTATION_COUNT='101')
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(len(metadata['jobs']),100)
            diagnostic=metadata['diagnostics']
            self.assertTrue(diagnostic['jobsTruncated'])
            self.assertTrue(diagnostic['annotationJobsTruncated'])
            self.assertEqual(len(diagnostic['annotations']),8)
            for annotation in diagnostic['annotations']:
                self.assertTrue(annotation['truncated'])
                self.assertEqual(len(annotation['entries']),100)
            calls=[json.loads(line) for line in (root/'commands').read_text().splitlines()]
            self.assertEqual(sum('/annotations?' in ' '.join(call) for call in calls),8)

    def test_unexpected_check_url_is_not_followed_and_job_is_retained(self):
        for url in ['https://elsewhere.invalid/check-runs/7001',
                'https://api.github.com/repos/fixture/builders/check-runs/invalid']:
            with self.subTest(url=url),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                result,metadata=self.reap(root,CHECK_URL=url)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(len(metadata['jobs']),1)
                self.assertIsNone(metadata['jobs'][0]['checkRunId'])
                self.assertEqual(metadata['diagnostics']['annotations'][0]['status'],'unavailable')
                self.assertNotIn('/annotations?',(root/'commands').read_text())


if __name__=='__main__':unittest.main()
