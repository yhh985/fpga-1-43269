"""Negative checks for release provenance without touching a real FPGA build."""
from pathlib import Path
import json, sys, tempfile, unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import build_verified as build

class BuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fpga_provenance_')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root/'hx4s20'
        (self.folder/'hdl').mkdir(parents=True)
        (self.folder/'contest_proj.al').write_text('<Project><Source_Files><File Path="hdl/top.v"/></Source_Files></Project>')
        (self.folder/'hdl/top.v').write_text('module top; endmodule')
        (self.folder/'hdl/font.mem').write_text('00\n')
        (self.folder/'build_verified_separate.tcl').write_text('top_module top')
        self.patch = patch.object(build, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.bit = self.folder/'test.bit'
        self.bit.write_bytes(b'known bitstream')
        (self.folder/'verified_build_complete.txt').write_text('VERIFIED_BUILD_COMPLETE test.bit')
        self.record = dict(passed=True, inputs=build.inputs('hx4s20'),
                           outputs={str(p.relative_to(self.root)):build.sha(p) for p in [self.bit,self.folder/'contest_proj.al']})
        (self.folder/'verified_build_inputs.json').write_text(json.dumps(self.record))

    def test_unchanged_build_accepts(self):
        build.validate_record('hx4s20')

    def test_modified_hdl_rejects(self):
        (self.folder/'hdl/top.v').write_text('module top; wire changed; endmodule')
        with self.assertRaisesRegex(AssertionError, 'inputs changed'):
            build.validate_record('hx4s20')

    def test_modified_memory_dependency_rejects(self):
        (self.folder/'hdl/font.mem').write_text('ff\n')
        with self.assertRaisesRegex(AssertionError, 'inputs changed'):
            build.validate_record('hx4s20')

    def test_changed_manifest_source_list_rejects(self):
        (self.folder/'contest_proj.al').write_text('<Project><File Path="hdl/font.mem"/></Project>')
        with self.assertRaisesRegex(AssertionError, 'inputs changed'):
            build.validate_record('hx4s20')

    def test_modified_bitstream_rejects(self):
        self.bit.write_bytes(b'wrong version')
        with self.assertRaisesRegex(AssertionError, 'output changed'):
            build.validate_record('hx4s20')

    def test_changed_project_options_rejects(self):
        (self.folder/'contest_proj.al').write_text('<Project><Source_Files><File Path="hdl/top.v"/></Source_Files><Property Name="changed"/></Project>')
        with self.assertRaisesRegex(AssertionError, 'output changed'):
            build.validate_record('hx4s20')

    def test_missing_completion_rejects(self):
        (self.folder/'verified_build_complete.txt').write_text('FAILED')
        with self.assertRaises(AssertionError):
            build.validate_record('hx4s20')

if __name__ == '__main__':
    unittest.main(verbosity=2)
