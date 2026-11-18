-- 2026-11-18 同桌文字評價：檢字規則修正
-- 2026-11-18_同桌文字評價.sql 跑的時候，線上拿到的是舊的檢字規則，會誤擋兩種正常的話：
--   「人很值得信賴」（單獨的「賴」）、「線上 online 也約」（單獨的 line）
-- 這份只換 _review_text_problem 一支（簽名不變 ⇒ create or replace，不丟權限）

create or replace function public._review_text_problem(p_body text)
returns text language plpgsql immutable as $$
declare
  t text := lower(regexp_replace(coalesce(p_body, ''), '\s+', '', 'g'));
begin
  -- 連續 7 個以上數字（中間可以有 - 或空白）＝ 電話號碼
  if coalesce(p_body, '') ~ '[0-9０-９][0-9０-９ \-]{5,}[0-9０-９]' then
    return '不能留電話號碼或 LINE ID，請改一下再送出';
  end if;
  -- ⚠ 不寫單獨的「賴」（會擋到「值得信賴」），也不寫單獨的 line（會擋到 online）
  if t ~ '((^|[^a-z])line|ｌｉｎｅ|加賴|我的賴|賴[:：]|賴id|微信|wechat|instagram|telegram|@[a-z0-9._]{3,})' then
    return '不能留電話號碼或 LINE ID，請改一下再送出';
  end if;
  if t ~ '(賭|輸錢|贏錢|下注|現金|轉帳|匯款|抽頭)' then
    return '這句話有不能使用的字（牌桌上不談錢），請改一下再送出';
  end if;
  if t ~ '(幹你|幹妳|幹林|幹拎|幹恁|操你|靠北|靠杯|靠腰|他媽|你媽|三小|王八|白痴|白癡|智障|去死|廢物|腦殘|垃圾|雞掰|機掰|婊)' then
    return '這句話有不適合的字，請改一下再送出';
  end if;
  return null;
end $$;
revoke execute on function public._review_text_problem(text) from public, anon, authenticated;

-- 驗證（單一 SELECT）
select * from (values
  ('① 擋得住：電話',          public._review_text_problem('加我 0912-345-678') is not null),
  ('② 擋得住：我的賴',        public._review_text_problem('我的賴 abc123') is not null),
  ('③ 擋得住：line 帳號',     public._review_text_problem('加我 line：abc123') is not null),
  ('④ 擋得住：賭博用詞',      public._review_text_problem('輸錢也笑笑的') is not null),
  ('⑤ 擋得住：髒話',          public._review_text_problem('靠北很慢') is not null),
  ('⑥ 不誤擋：值得信賴',      public._review_text_problem('人很值得信賴') is null),
  ('⑦ 不誤擋：online',        public._review_text_problem('線上 online 也約') is null),
  ('⑧ 不誤擋：牌品有待加強',  public._review_text_problem('牌品有待加強') is null),
  ('⑨ 不誤擋：10 點準時到',   public._review_text_problem('10 點準時到') is null),
  ('⑩ 前端叫不動',            not has_function_privilege('authenticated', 'public._review_text_problem(text)', 'execute')
                           and not has_function_privilege('anon', 'public._review_text_problem(text)', 'execute'))
) v(項目, 通過);
