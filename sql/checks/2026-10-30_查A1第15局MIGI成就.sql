-- ════════════════════════════════════════════════════════════════════
-- 唯讀：A1 今天這場第 15 局多記的 MIGI，座位 1 那位拿到了哪些成就（2026-10-30）
--
-- 第 15 局已經改成只有中發白（sql/applied/2026-10-30_A1第15局拿掉MIGI.sql），
-- 但那一局確認時發出的 MIGI 成就事件不會跟著收回。這份只讀，用來決定收回要改哪幾列：
--   ① 座位 1 是誰、他現在掛的稱號
--   ② 哪幾枚成就是 MIGI 事件觸發的
--   ③ 他在那幾枚成就的狀態與進度
--   ④ 扣掉第 15 局之後，他還有幾局真的胡了 MIGI（決定該退回幾格進度）
--   ⑤ 第 15 局之後他收到的通知（成就解鎖通知要不要一起刪）
-- 一列都不寫。
-- ════════════════════════════════════════════════════════════════════

with p as (
  select sp.member_id
    from public.session_players sp
   where sp.session_id = '9ed1aeed-993f-45cc-a3e3-0e02afab6077'
     and sp.seat = 1
   order by sp.joined_at desc
   limit 1
), a as (
  select x.* from public.achievements x
   where x.trigger::text like '%migi_hu%' or x.code like 'migi%'
)
select
  (select jsonb_build_object('member_id', m.id, '暱稱', m.display_name, '目前稱號', m.title)
     from public.members m where m.id = (select member_id from p))                         as "① 座位 1",
  (select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'struct', a.struct,
                                       'trigger', a.trigger, 'grants_title', a.grants_title,
                                       'reward_points', a.reward_points) order by a.code)
     from a)                                                                                 as "② MIGI 成就",
  (select jsonb_agg(to_jsonb(ma) order by ma.updated_at)
     from public.member_achievements ma
    where ma.member_id = (select member_id from p)
      and ma.achievement_id in (select id from a))                                           as "③ 他的成就狀態",
  (select count(*)
     from public.hands h
     join public.session_players sp on sp.session_id = h.session_id and sp.seat = h.winner_seat
    where sp.member_id = (select member_id from p)
      and h.status = 'confirmed' and h.undone_at is null
      and h.patterns @> '[{"code":"migi"}]'::jsonb)                                          as "④ 現在還算 MIGI 的局數",
  (select jsonb_agg(to_jsonb(n) order by n.created_at)
     from public.app_notifications n
    where n.member_id = (select member_id from p)
      and n.created_at >= '2026-10-30 06:16:00+00')                                          as "⑤ 第 15 局之後的通知";
