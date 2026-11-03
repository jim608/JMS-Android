"""Execute the real Android configuration in a keyless synthetic Groovy DSL.

This does not invoke Gradle, Flutter, Android plugins, dependency resolution, or
any real signing file. Signed controls load only generated sentinel properties.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


GROOVY_FIXTURE = r"""
import org.codehaus.groovy.control.CompilerConfiguration

class GradleException extends RuntimeException {
    GradleException(String message) { super(message) }
}

class Node {
    Fixture fixture
    String path
    Map values = [:]
    Map children = [:]

    static void configure(Node target, Closure block) {
        Closure configured = block.rehydrate(target, block.owner, block.thisObject)
        configured.resolveStrategy = Closure.DELEGATE_FIRST
        configured.call()
    }

    def propertyMissing(String name) {
        if (name == 'fixture') return this.@fixture
        if (name == 'flutter') return fixture.flutter
        if (name == 'JavaVersion') return [VERSION_1_8: 'java8-sentinel']
        if (name == 'signingConfigs') return fixture.signingAccess('resolve')
        if (name == 'buildTypes') return fixture.buildTypes
        if (values.containsKey(name)) return values[name]
        if (children.containsKey(name)) return children[name]
        if (name in ['pickFirsts', 'excludes']) {
            values[name] = []
            return values[name]
        }
        throw new MissingPropertyException(name, getClass())
    }

    void propertyMissing(String name, Object value) { values[name] = value }

    def methodMissing(String name, Object rawArguments) {
        Object[] arguments = rawArguments as Object[]
        if (name == 'file') return fixture.file(arguments[0].toString())
        if (name == 'getDefaultProguardFile') return 'synthetic-proguard-default'
        if (arguments.length == 1 && arguments[0] instanceof Closure) {
            Node child
            if (name == 'signingConfigs') {
                child = fixture.signingAccess('closure')
            } else if (name == 'buildTypes') {
                child = fixture.buildTypes
            } else {
                if (!children.containsKey(name)) {
                    children[name] = new Node(fixture: fixture, path: path + '/' + name)
                }
                child = children[name]
            }
            configure(child, arguments[0] as Closure)
            return child
        }
        values[name] = arguments.length == 1 ? arguments[0] : arguments.toList()
        return values[name]
    }
}

class BuildTypes extends Node {
    void configureEach(Closure block) {
        children.values().each { Node child -> Node.configure(child, block) }
        fixture.configureEachCalls++
    }
}

class Fixture {
    File syntheticRoot
    boolean unsigned
    List filePaths = []
    List signingAccesses = []
    int configureEachCalls = 0
    Node android
    Node flutter
    Node signingConfigs
    BuildTypes buildTypes

    Fixture(File syntheticRoot, boolean unsigned) {
        this.syntheticRoot = syntheticRoot
        this.unsigned = unsigned
        flutter = new Node(fixture: this, path: 'flutter', values: [
            ndkVersion: 'synthetic-ndk', minSdkVersion: 24,
            versionCode: 67, versionName: '0.11.1-jms.58'
        ])
        signingConfigs = new Node(fixture: this, path: 'signingConfigs')
        Node debug = new Node(fixture: this, path: 'signingConfigs/debug',
                              values: [identity: 'synthetic-debug-signature'])
        signingConfigs.children.debug = debug
        signingConfigs.children.release = new Node(fixture: this,
                                                    path: 'signingConfigs/release')
        buildTypes = new BuildTypes(fixture: this, path: 'buildTypes')
        // Seed multiple variants so configureEach must clear inherited signing.
        buildTypes.children.debug = new Node(fixture: this, path: 'buildTypes/debug',
                                             values: [signingConfig: debug])
        buildTypes.children.profile = new Node(fixture: this, path: 'buildTypes/profile',
                                               values: [signingConfig: debug])
        buildTypes.children.release = new Node(fixture: this, path: 'buildTypes/release',
                                               values: [signingConfig: null])
        android = new Node(fixture: this, path: 'android')
    }

    Node signingAccess(String kind) {
        signingAccesses.add(kind)
        if (unsigned) throw new AssertionError('Unsigned signingConfigs access: ' + kind)
        return signingConfigs
    }

    File file(String relative) {
        filePaths.add(relative)
        if (relative in ['key.properties', 'keystore.jks'] ||
                relative.toLowerCase().contains('keystore')) {
            if (unsigned) throw new AssertionError('Unsigned signing-file access: ' + relative)
        }
        assert relative in ['key.properties', 'keystore.jks', 'local.properties'] : relative
        // Never return any path outside the temporary synthetic project.
        return new File(syntheticRoot, relative)
    }
}

abstract class FakeGradleScript extends Script {
    Fixture getFixture() { (Fixture) getBinding().getVariable('fixture') }
    def plugins(Closure ignored) { /* Never apply a real plugin. */ }
    def dependencies(Closure ignored) { /* Never resolve dependencies. */ }
    def android(Closure block) { Node.configure(fixture.android, block) }
    def flutter(Closure block) { Node.configure(fixture.flutter, block) }
    Node getFlutter() { fixture.flutter }
    def getJavaVersion() { [VERSION_1_8: 'java8-sentinel'] }
    def getRootProject() { this }
    File file(String relative) { fixture.file(relative) }
}

String scenario = args[0]
File actualSource = new File(args[1])
File syntheticRoot = new File(args[2])
boolean unsigned = System.getenv('JMS_UNSIGNED_CANDIDATE') == 'true'
Fixture fixture = new Fixture(syntheticRoot, unsigned)
CompilerConfiguration configuration = new CompilerConfiguration()
configuration.scriptBaseClass = FakeGradleScript.name
GroovyShell shell = new GroovyShell(this.class.classLoader,
                                    new Binding([fixture: fixture]), configuration)

if (scenario == 'conflict') {
    boolean rejected = false
    try {
        shell.evaluate(actualSource)
    } catch (GradleException error) {
        assert error.message == 'Unsigned candidates cannot use JMS test signing'
        rejected = true
    }
    assert rejected : 'Conflicting signing modes were accepted'
    assert fixture.filePaths.empty : fixture.filePaths
    assert fixture.signingAccesses.empty : fixture.signingAccesses
    println('PASS conflict: rejected before file or signing configuration access')
    return
}

shell.evaluate(actualSource)
assert fixture.android.children.defaultConfig.values.applicationId == 'com.jim608.jms'
if (scenario == 'unsigned') {
    assert fixture.filePaths == ['local.properties'] : fixture.filePaths
    assert fixture.signingAccesses.empty : fixture.signingAccesses
    assert fixture.configureEachCalls == 1
    assert fixture.buildTypes.children.keySet() == ['debug', 'profile', 'release'] as Set
    fixture.buildTypes.children.each { name, node ->
        assert node.values.containsKey('signingConfig')
        assert node.values.signingConfig == null : name
    }
    println('PASS unsigned: zero signing access; debug/profile/release signing is null')
} else {
    assert fixture.filePaths == ['key.properties', 'local.properties', 'keystore.jks']
    assert fixture.signingAccesses == ['closure', 'resolve'] : fixture.signingAccesses
    assert fixture.configureEachCalls == 0
    Node production = fixture.signingConfigs.children.release
    assert production.values.keyAlias == 'SYNTHETIC_ALIAS'
    assert production.values.keyPassword == 'SYNTHETIC_KEY_PASSWORD'
    assert production.values.storePassword == 'SYNTHETIC_STORE_PASSWORD'
    assert production.values.storeFile == new File(syntheticRoot, 'keystore.jks')
    assert !production.values.storeFile.exists() : 'Fixture must not create any keystore'
    Node expected = scenario == 'signed-test' ? fixture.signingConfigs.children.debug : production
    assert fixture.buildTypes.children.release.values.signingConfig.is(expected)
    println('PASS ' + scenario + ': synthetic properties loaded; expected signing config selected')
}
"""


class ActualAndroidUnsignedConfigurationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = Path(__file__).resolve().parents[1] / "android/app/build.gradle"
        cls.java = shutil.which("java")
        if not cls.java:
            raise RuntimeError("Java is required for the isolated Groovy fixture")
        distributions = Path.home() / ".gradle/wrapper/dists/gradle-8.13-all"
        jars = sorted(distributions.glob("*/gradle-8.13/lib/groovy-3.0.22.jar"))
        if not jars:
            raise RuntimeError("Cached Gradle 8.13 Groovy 3.0.22 jar is required; no download is attempted")
        cls.groovy = jars[0]

    def run_configuration(self, scenario: str, *, unsigned: bool, test_signing: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="jms-unsigned-gradle-fixture-") as temporary:
            root = Path(temporary)
            fixture = root / "isolated_android_configuration.groovy"
            fixture.write_text(GROOVY_FIXTURE, encoding="utf-8")
            (root / "key.properties").write_text(
                "keyAlias=SYNTHETIC_ALIAS\n"
                "keyPassword=SYNTHETIC_KEY_PASSWORD\n"
                "storePassword=SYNTHETIC_STORE_PASSWORD\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            for name in ("JMS_UNSIGNED_CANDIDATE", "JMS_TEST_SIGNING"):
                environment.pop(name, None)
            if unsigned:
                environment["JMS_UNSIGNED_CANDIDATE"] = "true"
            if test_signing:
                environment["JMS_TEST_SIGNING"] = "true"
            result = subprocess.run(
                [self.java, "-cp", str(self.groovy), "groovy.ui.GroovyMain",
                 str(fixture), scenario, str(self.source), str(root)],
                env=environment,
                cwd=root,
                text=True,
                capture_output=True,
                timeout=45,
                check=False,
            )
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr)[-5000:])
            self.assertIn("PASS " + scenario + ":", result.stdout)

    def test_unsigned_clears_every_build_type_without_signing_access(self) -> None:
        self.run_configuration("unsigned", unsigned=True, test_signing=False)

    def test_unsigned_test_signing_conflict_fails_before_access(self) -> None:
        self.run_configuration("conflict", unsigned=True, test_signing=True)

    def test_default_signing_loads_synthetic_production_properties(self) -> None:
        self.run_configuration("signed-production", unsigned=False, test_signing=False)

    def test_test_signing_loads_synthetic_properties_and_selects_debug(self) -> None:
        self.run_configuration("signed-test", unsigned=False, test_signing=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
