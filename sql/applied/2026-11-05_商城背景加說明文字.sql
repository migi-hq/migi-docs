/* ============================================================
   2026-11-05 · 牌桌商城：每一款背景加一段說明（使用者：抽屜的標題小字改成相關說明，參考設定集）
   · shop_items 加 description（說明是商品資料，跟名稱、價格一樣放後端；改文字不用重新部署）
   · get_my_shop_tx 多回 description（CREATE OR REPLACE、簽名不變、授權不掉）
   · 文字照《小熊宇宙》設定集（docs/03-會員App與社交/小熊宇宙.md，在 claude/bear-universe 分支）：
     大熊星座是自然景觀、勺口兩顆星指著北方；歐拉小鎮的窗台燈與冬夜星空；燈塔島的燈塔；鎮上的老櫻樹
   · 已下架的兩款也填：兌換過的人仍會在商城看到它們
   ============================================================ */

alter table public.shop_items add column if not exists description text;
comment on column public.shop_items.description is '牌桌商城抽屜裡標題下面那段說明（一兩句，照小熊宇宙設定集）';

update public.shop_items set description = case code
  when 'starry' then '迷路的船抬頭找到它，就知道家在哪個方向。'
  when 'town'   then '沒有雲的冬夜，滿天星星壓得很低，是歐拉小鎮最美的時候。'
  when 'storm'  then '主島最外面的岩石上有一座燈塔。暴風雨的晚上看不見星星，燈塔就替海上的船點一顆不會被雨遮住的星。'
  when 'sakura' then '春天的晚上，歐拉小鎮那幾棵老櫻樹開花了，花瓣隨風落在石板路上。'
  else description end;

create or replace function public.get_my_shop_tx()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_me uuid := public.current_member_id();
  v_bg text;
begin
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  v_bg := public._member_table_bg(v_me);
  return jsonb_build_object(
    'shard', coalesce((select sum(qty) from shard_grants where member_id = v_me), 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', i.code, 'kind', i.kind, 'name', i.name, 'tier', i.tier, 'price', i.price,
               'description', i.description,   -- 抽屜標題下面的說明（2026-11-05）
               'owned', i.tier = 'default' or mi.item_code is not null,
               'equipped', i.kind = 'table_bg' and i.code = v_bg)
             order by i.sort, i.code)
        from shop_items i
        left join member_items mi on mi.member_id = v_me and mi.item_code = i.code
       where i.is_active or mi.item_code is not null), '[]'::jsonb));
end $function$;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select count(*) from shop_items where description is null or description = '') = 0
       then '✅ ① 四款都有說明' else '🔴 ① 還有沒寫說明的：' || (select string_agg(code, '、') from shop_items where coalesce(description, '') = '') end,
  case when pg_get_functiondef('public.get_my_shop_tx'::regproc) ~ '''description'', i\.description'
       then '✅ ② get_my_shop_tx 回 description' else '🔴 ② get_my_shop_tx 沒有回 description' end,
  case when has_function_privilege('authenticated', 'public.get_my_shop_tx()', 'EXECUTE')
       then '✅ ③ 會員叫得動（授權沒掉）' else '🔴 ③ authenticated 叫不動 get_my_shop_tx' end,
  case when (select count(*) from pg_proc where proname = 'get_my_shop_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅ ④ 只有一個版本' else '🔴 ④ 版本數不是 1' end
) as "驗證";
