# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

"""Validate that image-mappings deployment keys match OpenStackVersion fields.

``containers/image-mappings.yaml`` declares which
``OpenStackVersion.spec.customContainerImages`` fields each built image
should be assigned to.  This test ensures those keys are real fields in
the openstack-operator CRD, catching drift before it reaches a cluster.

The canonical field list is extracted at test time from the Go source in
an adjacent openstack-operator checkout when available.  A frozen
fallback set is embedded for CI environments where that checkout is
absent.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
IMAGE_MAPPINGS = REPO_ROOT / "containers" / "image-mappings.yaml"

_OPENSTACK_OPERATOR_CANDIDATES = [
    REPO_ROOT.parent / "openstack-operator",
    REPO_ROOT.parents[1] / "openstack-operator",
]

_TYPES_FILE = "api" / pathlib.PurePosixPath(
    "core/v1beta1/openstackversion_types.go"
)

# Frozen set extracted from openstack-operator ContainerTemplate on main
# as of 2026-08-12.  Update by running this test with an openstack-operator
# checkout available — test_frozen_set_matches_live_source reports the diff.
KNOWN_VALID_KEYS = frozenset(
    {
        "agentImage",
        "ansibleeeImage",
        "aodhAPIImage",
        "aodhEvaluatorImage",
        "aodhListenerImage",
        "aodhNotifierImage",
        "apacheImage",
        "barbicanAPIImage",
        "barbicanKeystoneListenerImage",
        "barbicanWorkerImage",
        "ceilometerCentralImage",
        "ceilometerComputeImage",
        "ceilometerIpmiImage",
        "ceilometerMysqldExporterImage",
        "ceilometerNotificationImage",
        "ceilometerSgcoreImage",
        "cinderAPIImage",
        "cinderBackupImage",
        "cinderSchedulerImage",
        "cinderVolumeImage",
        "cloudkittyAPIImage",
        "cloudkittyProcImage",
        "designateAPIImage",
        "designateBackendbind9Image",
        "designateCentralImage",
        "designateMdnsImage",
        "designateProducerImage",
        "designateUnboundImage",
        "designateWorkerImage",
        "edpmFrrImage",
        "edpmIscsidImage",
        "edpmKeplerImage",
        "edpmLogrotateCrondImage",
        "edpmMultipathdImage",
        "edpmNeutronDhcpAgentImage",
        "edpmNeutronMetadataAgentImage",
        "edpmNeutronOvnAgentImage",
        "edpmNeutronSriovAgentImage",
        "edpmNodeExporterImage",
        "edpmOpenstackNetworkExporterImage",
        "edpmOvnBgpAgentImage",
        "edpmPodmanExporterImage",
        "glanceAPIImage",
        "heatAPIImage",
        "heatCfnapiImage",
        "heatEngineImage",
        "horizonImage",
        "infraDnsmasqImage",
        "infraMemcachedImage",
        "infraRedisImage",
        "ironicAPIImage",
        "ironicConductorImage",
        "ironicInspectorImage",
        "ironicNeutronAgentImage",
        "ironicPxeImage",
        "ironicPythonAgentImage",
        "keystoneAPIImage",
        "ksmImage",
        "manilaAPIImage",
        "manilaSchedulerImage",
        "manilaShareImage",
        "mariadbImage",
        "netUtilsImage",
        "neutronAPIImage",
        "novaAPIImage",
        "novaComputeImage",
        "novaConductorImage",
        "novaNovncImage",
        "novaSchedulerImage",
        "octaviaAPIImage",
        "octaviaHealthmanagerImage",
        "octaviaHousekeepingImage",
        "octaviaRsyslogImage",
        "octaviaWorkerImage",
        "openstackClientImage",
        "openstackNetworkExporterImage",
        "osContainerImage",
        "ovnControllerImage",
        "ovnControllerOvsImage",
        "ovnNbDbclusterImage",
        "ovnNorthdImage",
        "ovnSbDbclusterImage",
        "placementAPIImage",
        "rabbitmqImage",
        "swiftAccountImage",
        "swiftContainerImage",
        "swiftObjectImage",
        "swiftProxyImage",
        "telemetryNodeExporterImage",
        "testAnsibletestImage",
        "testHorizontestImage",
        "testTempestImage",
        "testTobikoImage",
        "watcherAPIImage",
        "watcherApplierImage",
        "watcherDecisionEngineImage",
    }
)


def _parse_container_image_keys(go_source: str) -> frozenset:
    """Extract JSON tag names from ContainerTemplate and ContainerDefaults.

    ContainerTemplate has the scalar image fields shared across
    CustomContainerImages, ContainerImages, and ContainerDefaults.
    ContainerDefaults adds cinderVolumeImage and manilaShareImage
    which are used as defaults for the corresponding map fields.
    Both structs contribute valid deployment key names.
    """
    target_structs = {"ContainerTemplate", "ContainerDefaults"}
    in_struct = False
    keys = set()
    for line in go_source.splitlines():
        for name in target_structs:
            if re.match(rf"^type {name} struct", line):
                in_struct = True
                break
        else:
            if in_struct:
                if line.strip() == "}":
                    in_struct = False
                    continue
                match = re.search(r'json:"(\w+?)(?:,omitempty)?"', line)
                if match:
                    tag = match.group(1)
                    if tag not in ("customContainerImages",):
                        keys.add(tag)
    return frozenset(keys)


def _find_openstack_operator_types() -> pathlib.Path | None:
    """Locate openstackversion_types.go in a peer checkout."""
    for candidate in _OPENSTACK_OPERATOR_CANDIDATES:
        types_path = candidate / _TYPES_FILE
        if types_path.is_file():
            return types_path
    return None


def _load_valid_keys() -> frozenset:
    """Return the set of valid customContainerImages field names.

    Prefers a live parse of the Go source when available, falling back
    to the frozen set.
    """
    types_path = _find_openstack_operator_types()
    if types_path is not None:
        source = types_path.read_text(encoding="utf-8")
        live = _parse_container_image_keys(source)
        if live:
            return live
    return KNOWN_VALID_KEYS


def _parse_image_mappings(path: pathlib.Path) -> dict[str, list[str]]:
    """Parse containers/image-mappings.yaml without PyYAML.

    Returns a dict of {target: [deployment_key, ...]} from the format:
        openstack_version:
          custom_container_images:
            glance/glance-api:
              - glanceAPIImage
    """
    mappings: dict[str, list[str]] = {}
    current_target = None
    in_section = False

    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped == "custom_container_images:":
            in_section = True
            continue
        if not in_section:
            continue
        if stripped.startswith("- "):
            if current_target is not None:
                mappings[current_target].append(stripped[2:].strip())
            continue
        target_match = re.match(r"^    (\S+):$", line)
        if target_match:
            current_target = target_match.group(1)
            mappings[current_target] = []
            continue
        if stripped and not line.startswith(" "):
            break

    return mappings


class DeploymentKeyValidationTest(unittest.TestCase):
    """Verify image-mappings deployment keys against OpenStackVersion CRD."""

    @classmethod
    def setUpClass(cls):
        cls.valid_keys = _load_valid_keys()
        cls.has_mappings = IMAGE_MAPPINGS.is_file()
        cls.mappings = (
            _parse_image_mappings(IMAGE_MAPPINGS) if cls.has_mappings else {}
        )

    def test_valid_keys_set_is_populated(self):
        self.assertGreater(
            len(self.valid_keys),
            50,
            "Valid key set appears truncated or empty",
        )

    def test_frozen_set_matches_live_source(self):
        types_path = _find_openstack_operator_types()
        if types_path is None:
            self.skipTest("openstack-operator checkout not found")
        source = types_path.read_text(encoding="utf-8")
        live = _parse_container_image_keys(source)
        self.assertTrue(live, "Failed to parse image key structs from Go")
        if live != KNOWN_VALID_KEYS:
            added = live - KNOWN_VALID_KEYS
            removed = KNOWN_VALID_KEYS - live
            parts = ["KNOWN_VALID_KEYS is stale — update the frozen set."]
            if added:
                parts.append(f"  New fields: {sorted(added)}")
            if removed:
                parts.append(f"  Removed fields: {sorted(removed)}")
            self.fail("\n".join(parts))

    def test_all_deployment_keys_are_valid_openstack_version_fields(self):
        if not self.has_mappings:
            self.skipTest("image-mappings.yaml not found (PR #65 not merged)")
        for target, keys in self.mappings.items():
            for key in keys:
                self.assertIn(
                    key,
                    self.valid_keys,
                    f"{target}: '{key}' is not a valid "
                    f"OpenStackVersion.spec.customContainerImages field",
                )

    def test_deployment_keys_are_not_duplicated_across_targets(self):
        if not self.has_mappings:
            self.skipTest("image-mappings.yaml not found (PR #65 not merged)")
        seen: dict[str, str] = {}
        for target, keys in self.mappings.items():
            for key in keys:
                if key in seen:
                    self.fail(
                        f"Deployment key '{key}' claimed by both "
                        f"'{seen[key]}' and '{target}'"
                    )
                seen[key] = target

    def test_mapped_targets_have_containerfiles(self):
        """Every target in image-mappings must have a Containerfile."""
        if not self.has_mappings:
            self.skipTest("image-mappings.yaml not found (PR #65 not merged)")
        containers_dir = REPO_ROOT / "containers"
        for target in self.mappings:
            containerfile = containers_dir / target / "Containerfile"
            self.assertTrue(
                containerfile.is_file(),
                f"Mapped target '{target}' has no Containerfile at "
                f"{containerfile.relative_to(REPO_ROOT)}",
            )

    def test_mapped_targets_have_at_least_one_key(self):
        """Every target in the mapping must declare at least one key."""
        if not self.has_mappings:
            self.skipTest("image-mappings.yaml not found (PR #65 not merged)")
        self.assertGreater(
            len(self.mappings),
            0,
            "image-mappings.yaml is present but contains no targets",
        )
        for target, keys in self.mappings.items():
            self.assertGreater(
                len(keys),
                0,
                f"Target '{target}' is mapped but declares no deployment keys",
            )


if __name__ == "__main__":
    unittest.main()
