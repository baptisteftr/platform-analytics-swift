import XCTest
import os

@testable import PlatformAnalytics

final class LifecycleTests: XCTestCase {
    func testObserverTranslatesNotifications() {
        let center = NotificationCenter()
        let received = OSAllocatedUnfairLock(initialState: [LifecycleObserver.Event]())
        let active = Notification.Name("test.active")
        let background = Notification.Name("test.background")
        let terminate = Notification.Name("test.terminate")
        var observer: LifecycleObserver? = LifecycleObserver(
            center: center, names: .init(active: [active], background: [background, terminate])
        ) { event in received.withLock { $0.append(event) } }
        XCTAssertNotNil(observer)

        center.post(name: active, object: nil)
        center.post(name: background, object: nil)
        center.post(name: terminate, object: nil)
        center.post(name: Notification.Name("other"), object: nil)
        XCTAssertEqual(received.withLock { $0 }, [.didBecomeActive, .didEnterBackground, .didEnterBackground])

        observer = nil
        center.post(name: active, object: nil)
        XCTAssertEqual(received.withLock { $0 }.count, 3, "plus rien après la libération")
    }

    func testSystemNamesCoverActiveBackgroundAndTerminate() {
        let names = LifecycleObserver.Names.system
        XCTAssertEqual(names.active.count, 1)
        XCTAssertEqual(names.background.count, 2)
    }

    func testAppExtensionsAreDetected() {
        XCTAssertTrue(
            Analytics.isAppExtension(bundlePath: "/private/var/containers/Bundle/App.app/PlugIns/Widget.appex"))
        XCTAssertFalse(Analytics.isAppExtension(bundlePath: "/private/var/containers/Bundle/App.app"))
    }

    func testDeviceInfo() {
        let device = Batch.Device.current()
        XCTAssertFalse(device.model.isEmpty)
        XCTAssertNotEqual(device.model, "unknown")
        XCTAssertTrue(device.osVersion.contains("."))
        XCTAssertEqual(Batch.Device.localeIdentifier(Locale(identifier: "fr_FR@calendar=buddhist")), "fr_FR")
        XCTAssertEqual(Batch.Device.localeIdentifier(Locale(identifier: "de")), "de")
    }

    func testIdentityIsCreatedOnceAndReused() {
        let store = MemoryStore()
        let identity = DeviceIdentity(store: store)
        let current = identity.current
        let loaded = identity.load()
        XCTAssertEqual(loaded.id, current)
        XCTAssertTrue(loaded.created, "créé par le getter, l'indicateur reste pour la première session")
        XCTAssertFalse(identity.load().created)
        XCTAssertEqual(DeviceIdentity(store: store).load().id, current)
        XCTAssertFalse(DeviceIdentity(store: store).load().created)
        XCTAssertNotNil(UUID(uuidString: current))
    }

    func testInvalidStoredIdentityIsReplaced() {
        let store = MemoryStore("not-a-uuid")
        let loaded = DeviceIdentity(store: store).load()
        XCTAssertTrue(loaded.created)
        XCTAssertEqual(store.stored, loaded.id)
    }
}
