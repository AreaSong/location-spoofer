import Foundation

extension SpoofSession {
    /// 绑定时捕获资格；新路线/继续播放取得新代次，退出只排空并接管成功收据。
    func bindRoutePlayback(
        _ route: RoutePlaybackController,
        preview: Bool = false,
        onLocationKept: @escaping (CoordinatePair) -> Void
    ) {
        route.onPlaybackIntent = { [weak self, weak route] in
            guard let self, let route, self.beginMovement() else { return false }
            self.bindRoutePlayback(route, preview: preview, onLocationKept: onLocationKept)
            return true
        }
        let generation = writeGeneration
        let intent = writeIntent
        guard let mode = writeMode else { return }
        route.applyCoordinate = { [weak self, weak route] pair in
            guard let self, let route, self.writeIntent == intent, self.acceptsWrite(generation: generation, mode: mode) else { return false }
            if preview {
                self.setPreviewActive(true, latitude: pair.wgs84.latitude, longitude: pair.wgs84.longitude)
                return true
            }
            let submission = route.submissionGeneration
            return await self.writeRoute(pair, offsetMeters: route.offsetMeters, maySubmit: { [weak route] in
                route?.submissionGeneration == submission
            }, onFailure: { [weak route] failure in
                route?.pushFailureMessage = failure.message
            })
        }
        route.onLocationKept = { [weak self] in
            guard let self, self.writeIntent == intent, self.acceptsWrite(generation: generation, mode: mode), let pair = self.writtenCoordinate else { return }
            let wgs = pair.wgs84
            self.adoptActiveLocation(latitude: wgs.latitude, longitude: wgs.longitude)
            onLocationKept(pair)
        }
    }

    func bindPhysicalWalk(
        _ walk: PhysicalWalkController,
        onLocationWritten: @escaping (CoordinatePair) -> Void
    ) {
        walk.onStart = { [weak self, weak walk] in
            guard let self, let walk, self.beginMovement() else { return false }
            let generation = self.writeGeneration
            let intent = self.writeIntent
            let walkGeneration = walk.generation
            guard let mode = self.writeMode else { return false }
            walk.applyCoordinate = { [weak self, weak walk] pair in
                guard let self, self.writeIntent == intent, self.acceptsWrite(generation: generation, mode: mode) else { return false }
                let applied = await self.writeMoving(pair, maySubmit: { [weak walk] in
                    walk?.isTracking == true && walk?.generation == walkGeneration
                })
                guard applied, self.writeIntent == intent, self.acceptsWrite(generation: generation, mode: mode) else { return false }
                if walk?.isTracking == true, walk?.generation == walkGeneration {
                    onLocationWritten(pair)
                }
                return true
            }
            walk.onStop = { [weak self, weak walk] in
                guard let self else { return }
                await self.waitForMovementWrite()
                guard self.writeIntent == intent, self.acceptsWrite(generation: generation, mode: mode),
                      walk?.isTracking == false, let pair = self.writtenCoordinate else { return }
                onLocationWritten(pair)
            }
            return true
        }
    }
}
