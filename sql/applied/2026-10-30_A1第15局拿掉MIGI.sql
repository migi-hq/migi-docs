-- ════════════════════════════════════════════════════════════════════
-- A1 今天這場（10/30）第 1 將第 15 局：拿掉多按的 MIGI，只留一個中發白（2026-10-30 現場回報）
--
-- 這一局：座位 1 胡、座位 4 放槍，莊家是座位 2（跟這一局無關 ⇒ 沒有莊家台），底 30、每台 10。
--   原本  中發白 ×1 ＋ MIGI   牌型 9 台   座位 1 +120　座位 4 −120
--   改成  中發白 ×1           牌型 1 台   座位 1 +40 　座位 4 −40
--   （30 ＋ 10 × 1 ＝ 40；總和仍是 0）
-- 後面幾局不受影響：誰胡、誰當莊都沒變。
--
-- ⚠ 安全閥：只在「那一局還是原本那組牌型與分數、還沒撤銷、這一場還沒算成績」時才改；
--   任何一項不符就整份不動，驗證會說原因。
-- ════════════════════════════════════════════════════════════════════

do $do$
declare
  v_hand uuid := '82a4c427-79af-4398-a5da-5b6275d7b98f';   -- A1 本場第 1 將第 15 局
  h record;
  v_scored boolean;
  v_msg text;
begin
  select id, session_id, status, undone_at, patterns, tai_pattern, score_delta into h
    from public.hands where id = v_hand for update;

  select exists (select 1 from public.session_players sp
                  where sp.session_id = h.session_id and sp.finish_rank is not null)
    into v_scored;

  if h.id is null then
    v_msg := '🔴 找不到這一局，沒有改';
  elsif h.status <> 'confirmed' or h.undone_at is not null then
    v_msg := '🔴 這一局已經不是「已入帳」（狀態 ' || h.status || '），沒有改';
  elsif v_scored then
    v_msg := '🔴 這一場已經算完成績了，改這一局不會反映到名次與段位分 —— 沒有改，請回報';
  elsif h.patterns <> '[{"n":1,"code":"triplet_dragon"},{"n":1,"code":"migi"}]'::jsonb
        or h.tai_pattern <> 9
        or h.score_delta <> '{"1":120,"2":0,"3":0,"4":-120}'::jsonb then
    v_msg := '🔴 這一局已經不是原本那組牌型與分數，沒有改';
  else
    update public.hands
       set patterns       = '[{"n":1,"code":"triplet_dragon"}]'::jsonb,
           tai_pattern    = 1,
           score_delta    = '{"1":40,"2":0,"3":0,"4":-40}'::jsonb,
           proposed_delta = '{"1":40,"2":0,"3":0,"4":-40}'::jsonb
     where id = h.id;
    v_msg := '✅ 第 15 局改成只有中發白 1 台：座位 1 +40、座位 4 −40';
  end if;
  perform set_config('migi.v', v_msg, true);
end
$do$;

-- 驗證（單一 SELECT）
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "結果",
       h.patterns::text    as "牌型（應該只有 triplet_dragon ×1）",
       h.tai_pattern       as "牌型台數（應該是 1）",
       h.score_delta::text as "分數（應該是 1:40、4:-40）"
  from public.hands h
 where h.id = '82a4c427-79af-4398-a5da-5b6275d7b98f';
