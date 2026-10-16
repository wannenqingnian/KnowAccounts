"""Check that Release retained the headless entrypoint and protected capture services."""
import argparse
import re
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('apk')
parser.add_argument('--aapt', default=shutil.which('aapt'))
args = parser.parse_args()
if not args.aapt:
    parser.error('Pass --aapt /path/to/Android/build-tools/aapt')

def dump(*items):
    return subprocess.check_output([args.aapt, 'dump', *items], text=True)

manifest = dump('xmltree', args.apk, 'AndroidManifest.xml')
for service, permission in [
    ('PaymentNotificationService', 'BIND_NOTIFICATION_LISTENER_SERVICE'),
    ('PaymentAccessibilityService', 'BIND_ACCESSIBILITY_SERVICE'),
]:
    assert service in manifest and 'android.permission.' + permission in manifest
assert 'android.accessibilityservice' in manifest
assert 'QUERY_ALL_PACKAGES' not in manifest
assert 'android.permission.SYSTEM_ALERT_WINDOW' in manifest, 'User-requested bookkeeping popup permission missing'
assert 'android.permission.POST_NOTIFICATIONS' in manifest, 'Shortcut notification permission missing'
assert 'ShortcutBootReceiver' in manifest, 'Shortcut notification restore receiver missing'
resources = dump('--values', 'resources', args.apk)
match = re.search(r'resource (0x[0-9a-f]+) .*:xml/payment_accessibility:[^\n]+\n\s+\(string8\) "([^"]+)"', resources)
assert match and '@' + match[1] in manifest, 'Accessibility metadata resource missing'
access = dump('xmltree', args.apk, match[2])
assert 'canRetrieveWindowContent' in access and 'canTakeScreenshot' in access and 'canPerformGestures' not in access
for package in ['com.tencent.mm', 'com.eg.android.AlipayGphone', 'com.jingdong.app.mall',
                'com.jd.jrapp', 'com.sankuai.meituan', 'com.sankuai.meituan.takeoutnew',
                'com.unionpay', 'com.taobao.taobao', 'com.xunmeng.pinduoduo',
                'com.ss.android.ugc.aweme', 'me.ele', 'com.sdu.didi.psnger',
                'com.huawei.wallet', 'com.dianping.v1', 'com.ss.android.ugc.aweme.lite',
                'com.ss.android.ugc.livelite', 'com.ss.android.yumme.video', 'com.wudaokou.hippo',
                'com.kuaishou.nebula', 'com.smile.gifmaker', 'com.alibaba.wireless',
                'com.taobao.idlefish', 'com.ccb.longjiLife']:
    assert package in access and package in manifest, package
with zipfile.ZipFile(args.apk) as archive:
    code = archive.read('lib/arm64-v8a/libapp.so')
    name = 'paymentAutomationWorker'
    assert name.encode() in code or name.encode('utf-16le') in code, 'Dart entrypoint stripped'
    dex = b''.join(archive.read(f) for f in archive.namelist() if f.endswith('.dex'))
    assert name.encode() in dex, 'Native dispatch missing'
    assert b'ScreenCaptureService' not in dex, 'MediaProjection capture service must not ship'
    for retained in ['takeConfirmation', 'authorizeConfirmation', 'confirmationResult', 'diagnostics', 'clearDiagnostics', 'workerTrace', '稍后填写', '保存记账', '搜索分类', '新增分类', '疑似重复', '未识别到明确账单', '请先授予知账悬浮窗权限', 'smart_ledger/shortcuts', 'quick_capture_ready', 'quick_ocr_matched', 'stopLocal']:
        assert retained.encode() in dex, 'Popup dispatch or form stripped: ' + retained
    for label in ['日志记录', '复制完整日志', '导出日志文件', '已读取本次页面提供的文本', '支付页面本地截图OCR增强', '通知栏快捷记账', 'OCR截图记账', '今日消费', '完成录音']:
        assert label.encode('utf-16le') in code or label.encode() in code, 'Diagnostic UI stripped: ' + label
print('PASS: headless worker, protected services, 23 sources, one-frame accessibility OCR and notification shortcuts retained')
