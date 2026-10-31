import EquinoxCore
import Foundation

final class WallpaperPreviewCoordinator {
	enum State {
		case empty
		case calculating
		case ready(URL, Int)
		case failed
	}

	typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
	typealias Executor = (@escaping () -> Void) -> Void

	private let service: WallpaperService
	private let schedule: Scheduler
	private let execute: Executor
	private let cancelPending: () -> Void
	private var revision = 0
	private var lastKey: String?
	private(set) var previewURL: URL?
	var stateDidChange: ((State) -> Void)?

	init(
		service: WallpaperService,
		schedule: @escaping Scheduler = { delay, work in
			DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
		},
		execute: Executor? = nil
	) {
		self.service = service
		self.schedule = schedule
		if let execute = execute {
			self.execute = execute
			self.cancelPending = {}
		} else {
			let queue = OperationQueue()
			queue.qualityOfService = .utility
			queue.maxConcurrentOperationCount = 1
			self.execute = { work in queue.addOperation(work) }
			self.cancelPending = { queue.cancelAllOperations() }
		}
	}

	deinit {
		cancelPending()
		if let url = previewURL { try? FileManager.default.removeItem(at: url) }
	}

	func update(_ attributes: [ImageAttributes], settings: ImageExportSettings) {
		let key = Self.key(attributes, settings: settings)
		guard key != lastKey else { return }
		lastKey = key
		revision += 1
		cancelPending()
		let currentRevision = revision
		if let url = previewURL { try? FileManager.default.removeItem(at: url) }
		previewURL = nil
		guard !attributes.isEmpty else {
			stateDidChange?(.empty)
			return
		}
		stateDidChange?(.calculating)
		schedule(0.6) { [weak self] in
			guard let self = self, currentRevision == self.revision else { return }
			let service = self.service
			self.execute { [weak self] in
				do {
					let data = try service.createWallpaper(
						attributes, settings: settings, progressCallback: nil
					)
					let url = FileManager.default.temporaryDirectory
						.appendingPathComponent(UUID().uuidString)
						.appendingPathExtension("heic")
					try data.write(to: url, options: .atomic)
					DispatchQueue.main.async { [weak self] in
						guard let self = self,
							currentRevision == self.revision else {
							try? FileManager.default.removeItem(at: url)
							return
						}
						self.previewURL = url
						self.stateDidChange?(.ready(url, data.count))
					}
				} catch {
					DispatchQueue.main.async { [weak self] in
						guard let self = self,
							currentRevision == self.revision else { return }
						self.stateDidChange?(.failed)
					}
				}
			}
		}
	}

	private static func key(
		_ attributes: [ImageAttributes], settings: ImageExportSettings
	) -> String {
		let images = attributes.map { attribute in
			let timing: String
			switch attribute.imageType {
			case .solar(let altitude, let azimuth):
				timing = "solar:\(altitude):\(azimuth)"
			case .time(let date):
				timing = "time:\(date.timeIntervalSinceReferenceDate)"
			case .appearance:
				timing = "appearance"
			}
			let appearance = String(describing: attribute.appearanceType)
			return "\(attribute.url.path):\(attribute.sourceIndex ?? -1):"
				+ "\(attribute.primary):\(appearance):" + timing
		}.joined(separator: "|")
		return "\(images)|\(settings.lossyCompressionScope)|"
			+ "\(settings.imageQuality)"
	}
}
