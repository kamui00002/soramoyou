// ⭐️ 写真の写し（WorkingPhotoImporter）の偽物。メモリの中だけで、呼ばれた引数を控え、結果をテストが決める（Kiro android-edit-tools タスク 2.4・K0・design.md:777）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import kotlinx.coroutines.CompletableDeferred

/**
 * 端末のファイルに触らない偽物。
 *
 * - 呼ばれた uid と写真を [calls] に控える
 * - 返す写真は [result] でテストが決める。既定は「写さなかった」形（元の URI のまま・relativeFile は null・撮影日時は null）で、
 *   K0 の ViewModel が読めた写真から作る形（PostComposerViewModel の onPhotosPicked）と同じ
 * - [gate] を置くと、呼び出しは記録した後、ゲートが完了するまで戻らない（写している間の状態を見るため）。
 *   ゲートは 1 回きりで、完了させると後の呼び出しも待たずに通る
 */
class FakeWorkingPhotoImporter : WorkingPhotoImporter {
    val calls = mutableListOf<Pair<Uid, List<PickedPhoto>>>()
    var result: (uid: Uid, photos: List<PickedPhoto>) -> List<WorkingPhoto> = { _, photos ->
        photos.map { WorkingPhoto(it.uri, relativeFile = null, capturedAt = null) }
    }
    var gate: CompletableDeferred<Unit>? = null

    override suspend fun import(uid: Uid, photos: List<PickedPhoto>): List<WorkingPhoto> {
        calls += uid to photos
        gate?.await()
        return result(uid, photos)
    }
}
