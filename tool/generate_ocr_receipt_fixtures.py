"""Generate anonymous OCR fixtures with varied field roles/layouts."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parents[1]/'test/fixtures/ocr-receipts'
FONT='/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
CASES={
 'order': ['支付宝', '付款成功', '商家名称：远方咖啡店', '订单金额：36.20元', '优惠金额：5.00元', '实付金额：31.20元', '账户余额：980.00元', '付款方式：余额宝', '创建时间：2026-10-02 08:20', '支付时间：2026-10-03 12:20'],
 'retail': ['邻里超市消费凭证', '牛奶 12.50元', '水果 20.00元', '合计：32.50元', '现金：50.00元', '找零：17.50元', '付款方式：微信', '交易时间：2026-10-03 18:00'],
 'bank': ['消费成功', '商户名称：城市书店', '交易金额：1,234.56元', '付款账户：招商银行(1234)', '交易时间：2026-10-03 15:04', '账户余额：50,000.00元'],
}
ROOT.mkdir(parents=True,exist_ok=True)
font=ImageFont.truetype(FONT,38)
for key,lines in CASES.items():
 im=Image.new('RGB',(980,1050),'white');d=ImageDraw.Draw(im)
 for i,line in enumerate(lines):d.text((60,55+i*84),line,font=font,fill='#222222')
 im.save(ROOT/f'{key}.png')
