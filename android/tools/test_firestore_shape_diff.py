#!/usr/bin/env python3
"""test_firestore_shape_diff.py ⭐️☁️

firestore_shape_diff.py（タスク 17.2・要件 17.7）の単体テスト。本番には繋がない（取得は偽物の opener で差し替える）。

実行: python3 -m unittest discover -s android/tools -p 'test_*.py'
"""
import io
import json
import os
import sys
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import firestore_shape_diff as fsd

# 検査で「値が出力に漏れていない」ことを確かめるための目印。どの値にもこの文字列を含める
SECRET_MARK = "LEAKCHECK"


def s(v=SECRET_MARK + "-str"):
    return {"stringValue": v}


def i(v="7"):
    return {"integerValue": v}


def ts(v="2026-10-08T00:00:00Z"):
    return {"timestampValue": v}


def b(v=True):
    return {"booleanValue": v}


def arr(*values):
    return {"arrayValue": {"values": list(values)}} if values else {"arrayValue": {}}


def m(**fields):
    return {"mapValue": {"fields": fields}}


def android_user_fields():
    """Android の USER_CREATE（ShapeContracts.kt）どおりのユーザー文書"""
    return {
        "id": s(),
        "createdAt": ts(),
        "updatedAt": ts(),
        "email": s(SECRET_MARK + "@example.com"),
        "followersCount": i("0"),
        "followingCount": i("0"),
        "postsCount": i("0"),
        "notifyReactions": b(True),
        "notifyNewPostsFromFollowing": b(True),
        "notifyNewPostsFromEveryone": b(False),
    }


def ios_user_fields():
    """iOS で同じ操作をした後のユーザー文書（iOS だけが書くキーを含む）"""
    fields = android_user_fields()
    fields.update({
        "fcmToken": s(SECRET_MARK + "-token"),
        "fcmTokenUpdatedAt": ts(),
        "iapAccountToken": s(),
        "followedTags": arr(s(), s()),
        "customEditTools": arr(s()),
        "customEditToolsOrder": arr(s()),
        "blockedUserIds": arr(),
    })
    return fields


def android_post_fields():
    """Android の POST_CREATE（ShapeContracts.kt・設計書の posts の表）どおりの、写真 1 枚・キャプションとタグつきの投稿"""
    image = m(url=s(), width=i("1365"), height=i("2048"), order=i("0"), thumbnail=s(), storagePath=s(), thumbnailStoragePath=s())
    return {
        "postId": s(),
        "userId": s(),
        "images": arr(image),
        "visibility": s("private"),
        "likesCount": i("0"),
        "commentsCount": i("0"),
        "createdAt": ts(),
        "updatedAt": ts(),
        "caption": s(),
        "hashtags": arr(s(), s()),
        "capturedAt": ts(),
        "timeOfDay": s("evening"),
    }


def ios_post_fields():
    """iOS で同じ操作をした投稿（Post.swift:119-210・ImageInfo.swift:55-77 で iOS だけが書くキーを含む）"""
    fields = android_post_fields()
    external = m(hasAdjustments=b(False), isHDR=b(False), isLivePhoto=b(False), isPanorama=b(False),
                 formatIdentifier=s(), creationDate=ts(), exifCapturedAt=ts())
    image = m(url=s(), width=i("1536"), height=i("2048"), order=i("0"), thumbnail=s(), storagePath=s(),
              thumbnailStoragePath=s(), externalEditInfo=external)
    fields.update({
        "images": arr(image),
        "skyColors": arr(s(), s()),
        "skyType": s("clear"),
        "colorTemperature": i("5600"),
        "editSettings": m(brightness={"doubleValue": 0.0}),
        "originalImages": arr(m(url=s(), width=i("3024"), height=i("4032"), order=i("0"))),
    })
    return fields


def status_of(rows, path):
    for row in rows:
        if row.path == path:
            return row.status
    raise AssertionError(f"{path} の行がない: {[r.path for r in rows]}")


class ShapeOfTest(unittest.TestCase):
    def test_top_level_types(self):
        shape = fsd.shape_of({"a": s(), "b": i(), "c": {"doubleValue": 1.5}, "d": ts(), "e": b(), "f": {"nullValue": None}})
        self.assertEqual(shape["a"], {"string"})
        self.assertEqual(shape["b"], {"integer"})
        self.assertEqual(shape["c"], {"double"})
        self.assertEqual(shape["d"], {"timestamp"})
        self.assertEqual(shape["e"], {"boolean"})
        self.assertEqual(shape["f"], {"null"})

    def test_map_is_recursed_with_dotted_path(self):
        shape = fsd.shape_of({"loc": m(lat={"doubleValue": 1.0}, name=s())})
        self.assertEqual(shape["loc"], {"map"})
        self.assertEqual(shape["loc.lat"], {"double"})
        self.assertEqual(shape["loc.name"], {"string"})

    def test_array_elements_and_array_of_maps(self):
        shape = fsd.shape_of({
            "tags": arr(s(), s()),
            "images": arr(m(url=s(), width=i()), m(url=s(), thumbnail=s())),
            "empty": arr(),
        })
        self.assertEqual(shape["tags"], {"array"})
        self.assertEqual(shape["tags[]"], {"string"})
        self.assertEqual(shape["images[]"], {"map"})
        self.assertEqual(shape["images[].url"], {"string"})
        self.assertEqual(shape["images[].width"], {"integer"})
        self.assertEqual(shape["images[].thumbnail"], {"string"})
        self.assertEqual(shape["empty"], {"array"})
        self.assertNotIn("empty[]", shape)


class CompareTest(unittest.TestCase):
    def test_same_operation_shows_only_expected_differences(self):
        rows = fsd.compare(fsd.shape_of(android_user_fields()), fsd.shape_of(ios_user_fields()), "users")
        self.assertEqual(status_of(rows, "id"), fsd.MATCH)
        self.assertEqual(status_of(rows, "fcmToken"), fsd.EXPECTED)
        self.assertEqual(status_of(rows, "followedTags"), fsd.EXPECTED)
        # 配列の要素の行も、親のキーが想定内なら想定内
        self.assertEqual(status_of(rows, "followedTags[]"), fsd.EXPECTED)
        self.assertFalse(fsd.has_unexpected(rows))

    def test_type_difference_is_unexpected(self):
        android = android_user_fields()
        android["postsCount"] = {"doubleValue": 0.0}  # Android が整数でなく小数で書いた
        rows = fsd.compare(fsd.shape_of(android), fsd.shape_of(ios_user_fields()), "users")
        self.assertEqual(status_of(rows, "postsCount"), fsd.UNEXPECTED)
        self.assertTrue(fsd.has_unexpected(rows))

    def test_type_difference_on_expected_key_is_still_unexpected(self):
        # 想定内の差分は「片方にしか無い」ことだけ。両方にあって型が違うのは想定外
        android = android_user_fields()
        android["fcmToken"] = i()
        rows = fsd.compare(fsd.shape_of(android), fsd.shape_of(ios_user_fields()), "users")
        self.assertEqual(status_of(rows, "fcmToken"), fsd.UNEXPECTED)

    def test_key_only_on_android_is_unexpected(self):
        android = android_user_fields()
        android["platform"] = s()
        rows = fsd.compare(fsd.shape_of(android), fsd.shape_of(ios_user_fields()), "users")
        self.assertEqual(status_of(rows, "platform"), fsd.UNEXPECTED)

    def test_ios_only_key_outside_expected_list_is_unexpected(self):
        ios = ios_user_fields()
        ios["displayName"] = s()  # Android は同じ操作で書くはずの項目
        rows = fsd.compare(fsd.shape_of(android_user_fields()), fsd.shape_of(ios), "users")
        self.assertEqual(status_of(rows, "displayName"), fsd.UNEXPECTED)

    def test_expected_list_is_per_collection(self):
        # users では想定内の fcmToken も、publicProfiles に出たら想定外（公開プロフィールに機密が入っている）
        ios = {"id": s(), "fcmToken": s()}
        rows = fsd.compare(fsd.shape_of({"id": s()}), fsd.shape_of(ios), "publicProfiles")
        self.assertEqual(status_of(rows, "fcmToken"), fsd.UNEXPECTED)
        rows = fsd.compare(fsd.shape_of({"id": s()}), fsd.shape_of({"id": s(), "recommendedPostIds": arr(s())}), "publicProfiles")
        self.assertEqual(status_of(rows, "recommendedPostIds"), fsd.EXPECTED)
        self.assertEqual(status_of(rows, "recommendedPostIds[]"), fsd.EXPECTED)

    def test_posts_same_operation_shows_only_expected_differences(self):
        rows = fsd.compare(fsd.shape_of(android_post_fields()), fsd.shape_of(ios_post_fields()), "posts")
        self.assertEqual(status_of(rows, "hashtags[]"), fsd.MATCH)
        self.assertEqual(status_of(rows, "images[].url"), fsd.MATCH)
        self.assertEqual(status_of(rows, "skyType"), fsd.EXPECTED)
        self.assertEqual(status_of(rows, "originalImages[].url"), fsd.EXPECTED)
        # 配列の中のマップのキーも、想定内の道筋そのものと、その下の道筋は想定内（M4・タスク 25.3）
        self.assertEqual(status_of(rows, "images[].externalEditInfo"), fsd.EXPECTED)
        self.assertEqual(status_of(rows, "images[].externalEditInfo.exifCapturedAt"), fsd.EXPECTED)
        self.assertFalse(fsd.has_unexpected(rows))

    def test_nested_ios_only_key_outside_expected_list_is_unexpected(self):
        # 想定内なのは images[].externalEditInfo だけ。同じ images の中でも、表に無いキーは想定外のまま
        ios = ios_post_fields()
        ios["images"]["arrayValue"]["values"][0]["mapValue"]["fields"]["blurHash"] = s()
        ios["images"]["arrayValue"]["values"][0]["mapValue"]["fields"]["externalEditInfoV2"] = s()
        rows = fsd.compare(fsd.shape_of(android_post_fields()), fsd.shape_of(ios), "posts")
        self.assertEqual(status_of(rows, "images[].blurHash"), fsd.UNEXPECTED)
        # 名前の前方が同じだけのキー（区切りの . や [ が続かない）は、想定内のキーの下ではない
        self.assertEqual(status_of(rows, "images[].externalEditInfoV2"), fsd.UNEXPECTED)

    def test_nested_expected_key_written_by_android_is_compared_by_type(self):
        # Android が externalEditInfo を書いたら想定内ではなくなり、型が同じなら一致・違えば想定外
        android = android_post_fields()
        android["images"]["arrayValue"]["values"][0]["mapValue"]["fields"]["externalEditInfo"] = s()
        rows = fsd.compare(fsd.shape_of(android), fsd.shape_of(ios_post_fields()), "posts")
        self.assertEqual(status_of(rows, "images[].externalEditInfo"), fsd.UNEXPECTED)
        self.assertEqual(status_of(rows, "images[].externalEditInfo.isHDR"), fsd.UNEXPECTED)

    def test_unknown_collection_is_rejected(self):
        with self.assertRaises(ValueError):
            fsd.compare({}, {}, "follows")


class RenderTest(unittest.TestCase):
    def test_unexpected_rows_come_first_and_are_marked(self):
        android = android_user_fields()
        android["postsCount"] = {"doubleValue": 0.0}
        out = fsd.render(fsd.compare(fsd.shape_of(android), fsd.shape_of(ios_user_fields()), "users"))
        # 想定外の行に印が付き、想定内の行より前に並ぶ
        posts_line = next(ln for ln in out.splitlines() if "postsCount" in ln)
        self.assertIn("⚠️", posts_line)
        self.assertLess(out.index("postsCount"), out.index("fcmToken"))


class MainTest(unittest.TestCase):
    TOKEN = "ya29.TESTTOKEN-must-not-appear"

    def run_main(self, argv, opener):
        out, err = io.StringIO(), io.StringIO()
        code = fsd.main(argv, stdout=out, stderr=err, token_loader=lambda: self.TOKEN, opener=opener)
        return code, out.getvalue(), err.getvalue()

    def fake_opener(self, docs):
        seen = []

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def opener(req, timeout=None):
            seen.append(req)
            path = req.full_url.split("/documents/", 1)[1]
            return Resp(json.dumps({"name": path, "fields": docs[path]}).encode())

        opener.seen = seen
        return opener

    def test_fetches_read_only_and_never_prints_values_or_token(self):
        opener = self.fake_opener({"users/A": android_user_fields(), "users/B": ios_user_fields()})
        code, out, err = self.run_main(["--android", "users/A", "--ios", "users/B"], opener)
        self.assertEqual(code, 0, out + err)
        for req in opener.seen:
            self.assertEqual(req.get_method(), "GET")
            self.assertIn("/projects/soramoyou-ios/databases/(default)/documents/users/", req.full_url)
            self.assertEqual(req.get_header("Authorization"), "Bearer " + self.TOKEN)
        self.assertNotIn(SECRET_MARK, out + err)
        self.assertNotIn(self.TOKEN, out + err)

    def test_unexpected_difference_exits_1(self):
        android = android_user_fields()
        android["postsCount"] = {"doubleValue": 0.0}
        opener = self.fake_opener({"users/A": android, "users/B": ios_user_fields()})
        code, out, _ = self.run_main(["--android", "users/A", "--ios", "users/B"], opener)
        self.assertEqual(code, 1)
        self.assertIn("postsCount", out)

    def test_different_collections_are_rejected(self):
        opener = self.fake_opener({})
        code, _, err = self.run_main(["--android", "users/A", "--ios", "publicProfiles/B"], opener)
        self.assertEqual(code, 2)
        self.assertEqual(opener.seen, [])  # 取得の前に止める
        self.assertTrue(err)

    def test_http_error_does_not_leak_token_or_body(self):
        def opener(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"error":"' + SECRET_MARK.encode() + b'"}'))

        code, out, err = self.run_main(["--android", "users/A", "--ios", "users/B"], opener)
        self.assertEqual(code, 2)
        self.assertIn("401", err)
        self.assertNotIn(self.TOKEN, out + err)
        self.assertNotIn(SECRET_MARK, out + err)

    def test_local_files_need_collection(self):
        import tempfile

        with tempfile.TemporaryDirectory() as d:
            a, c = os.path.join(d, "a.json"), os.path.join(d, "c.json")
            with open(a, "w") as f:
                json.dump({"fields": android_user_fields()}, f)
            with open(c, "w") as f:
                json.dump({"fields": ios_user_fields()}, f)

            def no_network(req, timeout=None):
                raise AssertionError("ファイルの比較で通信してはいけない")

            code, _, _ = self.run_main(["--android-file", a, "--ios-file", c], no_network)
            self.assertEqual(code, 2)
            code, out, err = self.run_main(["--android-file", a, "--ios-file", c, "--collection", "users"], no_network)
            self.assertEqual(code, 0, out + err)
            self.assertNotIn(SECRET_MARK, out + err)


if __name__ == "__main__":
    unittest.main()
