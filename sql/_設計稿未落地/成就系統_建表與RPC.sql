-- 【成就系統・執行狀態待確認】achievements 表結構與核心 RPC。
-- ⚠️ 尚未確認此檔是否已在資料庫執行過。執行前請先查 achievements 表是否存在。
-- ============================================================
-- MIGI 成就系統 — 定義表 + 觸發 RPC + 65 個成就 seed
-- 對齊 MIGI_成就主清單_兩軸分類_v2.0.md。
-- 依賴:發放機制(grant_points_tx)+ v1.1 bucket(贈點進 bonus 池)。
-- 部署:Supabase Dashboard → SQL Editor → 貼上 → Run。
-- 結構 struct: specific 特定 / cumulative 累積 / streak 連續 / prestige 榮耀
--   is_hidden = 隱藏(同機制,UI 解鎖前不顯示)
-- 動機 motivation / 風味 flavor 為分類標籤(UI 篩選用)
-- ============================================================

-- ---------- 定義表 ----------
create table if not exists achievements (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete restrict,
  code         text not null,
  name         text not null,
  struct       text not null check (struct in ('specific','cumulative','streak','prestige')),
  is_hidden    boolean not null default false,
  motivation   text not null check (motivation in ('completion','competition','social','exploration','collection','prestige')),
  flavor       text check (flavor in ('mahjong','luck','wealth','girls','bear')),
  condition_text text,
  grants_title text,                 -- 榮耀:掛在名字旁的稱號
  is_signature boolean not null default false,  -- 品牌旗艦成就(MIGI 唯一)
  reward_points bigint not null default 0,  -- specific/prestige 一次性贈點(累積/連續用 tiers)
  rarity_cached numeric,             -- 持有率%,由定時 job 更新(稀有度)
  valid_from   timestamptz,          -- 限時檔期;null = 永久
  valid_to     timestamptz,
  is_active    boolean not null default true,
  sort         int not null default 0,
  deleted_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists uq_ach_code on achievements(org_id, code) where deleted_at is null;

-- ---------- 分級(累積/連續用) ----------
create table if not exists achievement_tiers (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,
  achievement_id uuid not null references achievements(id) on delete cascade,
  tier_level     int not null,                  -- 1=I 2=II 3=III 4=IV
  tier_name      text not null,
  threshold      bigint not null,
  reward_points  bigint not null default 0,
  unique(achievement_id, tier_level)
);

-- ---------- 會員進度 ----------
create table if not exists member_achievements (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,
  member_id      uuid not null references members(id) on delete restrict,
  achievement_id uuid not null references achievements(id) on delete restrict,
  status         text not null default 'locked' check (status in ('locked','in_progress','unlocked')),
  current_value  bigint not null default 0,     -- 累積/連續計數
  current_tier   int not null default 0,
  last_period    text,                           -- 連續用:最後達成的日/週/月鍵
  pinned         boolean not null default false, -- 釘到個人展示櫃(榮耀炫耀)
  unlocked_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique(member_id, achievement_id)
);
create index if not exists idx_ma_member on member_achievements(org_id, member_id);

-- ---------- RLS ----------
alter table achievements        enable row level security;
alter table achievement_tiers   enable row level security;
alter table member_achievements enable row level security;
do $$ begin
  create policy p_ach_sel    on achievements        for select using (org_id = current_org_id());
  create policy p_acht_sel   on achievement_tiers   for select using (org_id = current_org_id());
  create policy p_ma_sel     on member_achievements for select using (org_id = current_org_id());
exception when duplicate_object then null; end $$;

-- ============================================================
-- 觸發 RPC(由事件層呼叫;皆檢查限時視窗、冪等、贈點走 bonus)
-- ============================================================

-- 內部:取會員進度列(鎖),不存在則建
create or replace function _ma_row(p_member uuid, p_ach uuid, p_org uuid) returns member_achievements
language plpgsql as $$
declare r member_achievements;
begin
  select * into r from member_achievements where member_id=p_member and achievement_id=p_ach for update;
  if not found then
    insert into member_achievements(org_id,member_id,achievement_id) values(p_org,p_member,p_ach)
      returning * into r;
  end if;
  return r;
end $$;

-- 內部:成就是否在有效視窗
create or replace function _ach_live(a achievements) returns boolean language sql as $$
  select a.is_active and a.deleted_at is null
     and (a.valid_from is null or now() >= a.valid_from)
     and (a.valid_to   is null or now() <= a.valid_to);
$$;

-- 特定/隱藏/榮耀:達成即解鎖(一次性)
create or replace function ach_unlock_tx(p_member uuid, p_code text, p_idem text default null)
returns jsonb language plpgsql as $$
declare v_org uuid; a achievements; r member_achievements;
begin
  select org_id into v_org from members where id=p_member;
  if v_org is null then raise exception '會員不存在'; end if;
  select * into a from achievements where org_id=v_org and code=p_code and deleted_at is null;
  if not found then raise exception '成就不存在: %', p_code; end if;
  if not _ach_live(a) then return jsonb_build_object('skipped','out_of_window'); end if;
  r := _ma_row(p_member, a.id, v_org);
  if r.status='unlocked' then return jsonb_build_object('already',true); end if;
  update member_achievements set status='unlocked', current_tier=1, unlocked_at=now(), updated_at=now()
    where id=r.id;
  if a.reward_points>0 then
    perform grant_points_tx(p_member, a.reward_points, 'ach:'||p_code, coalesce(p_idem,'ach:'||p_code||':'||p_member::text));
  end if;
  return jsonb_build_object('unlocked',true,'title',a.grants_title,'reward',a.reward_points);
end $$;

-- 累積:加計數,跨門檻自動解級並逐級贈點
create or replace function ach_progress_tx(p_member uuid, p_code text, p_delta bigint default 1, p_idem text default null)
returns jsonb language plpgsql as $$
declare v_org uuid; a achievements; r member_achievements; v_new bigint; v_tier int; v_max int; t record; v_granted bigint:=0;
begin
  select org_id into v_org from members where id=p_member;
  if v_org is null then raise exception '會員不存在'; end if;
  select * into a from achievements where org_id=v_org and code=p_code and deleted_at is null;
  if not found then raise exception '成就不存在: %', p_code; end if;
  if a.struct not in ('cumulative','streak') then raise exception '% 非累積型', p_code; end if;
  if not _ach_live(a) then return jsonb_build_object('skipped','out_of_window'); end if;
  r := _ma_row(p_member, a.id, v_org);
  if r.status='unlocked' then return jsonb_build_object('already',true,'value',r.current_value); end if;
  v_new := r.current_value + p_delta;
  select coalesce(max(tier_level),0) into v_max from achievement_tiers where achievement_id=a.id;
  select coalesce(max(tier_level),0) into v_tier from achievement_tiers where achievement_id=a.id and threshold <= v_new;
  -- 對新跨過的每一級贈點
  for t in select * from achievement_tiers where achievement_id=a.id and tier_level > r.current_tier and tier_level <= v_tier order by tier_level loop
    if t.reward_points>0 then
      perform grant_points_tx(p_member, t.reward_points, 'ach:'||p_code||':t'||t.tier_level,
                              coalesce(p_idem,'ach:'||p_code||':'||p_member::text)||':t'||t.tier_level);
      v_granted := v_granted + t.reward_points;
    end if;
  end loop;
  update member_achievements set current_value=v_new, current_tier=greatest(current_tier,v_tier),
    status = case when v_tier>=v_max and v_max>0 then 'unlocked' when v_new>0 then 'in_progress' else 'locked' end,
    unlocked_at = case when v_tier>=v_max and v_max>0 and unlocked_at is null then now() else unlocked_at end,
    updated_at=now()
    where id=r.id;
  return jsonb_build_object('value',v_new,'tier',v_tier,'max',v_max,'granted',v_granted);
end $$;

-- 連續:advance=true 接續(+1)、false 中斷歸 1;再比門檻解級(沿用累積邏輯)
create or replace function ach_streak_tx(p_member uuid, p_code text, p_period_key text, p_advance boolean, p_idem text default null)
returns jsonb language plpgsql as $$
declare v_org uuid; a achievements; r member_achievements; v_new bigint; v_tier int; v_max int; t record; v_granted bigint:=0;
begin
  select org_id into v_org from members where id=p_member;
  if v_org is null then raise exception '會員不存在'; end if;
  select * into a from achievements where org_id=v_org and code=p_code and deleted_at is null;
  if not found then raise exception '成就不存在: %', p_code; end if;
  if a.struct <> 'streak' then raise exception '% 非連續型', p_code; end if;
  if not _ach_live(a) then return jsonb_build_object('skipped','out_of_window'); end if;
  r := _ma_row(p_member, a.id, v_org);
  if r.last_period is not null and r.last_period = p_period_key then
    return jsonb_build_object('dedup',true,'value',r.current_value); -- 同期間重送
  end if;
  v_new := case when p_advance then r.current_value + 1 else 1 end;
  select coalesce(max(tier_level),0) into v_max from achievement_tiers where achievement_id=a.id;
  select coalesce(max(tier_level),0) into v_tier from achievement_tiers where achievement_id=a.id and threshold <= v_new;
  for t in select * from achievement_tiers where achievement_id=a.id and tier_level > r.current_tier and tier_level <= v_tier order by tier_level loop
    if t.reward_points>0 then
      perform grant_points_tx(p_member, t.reward_points, 'ach:'||p_code||':t'||t.tier_level,
                              coalesce(p_idem, 'ach:'||p_code||':'||p_member::text||':'||p_period_key)||':t'||t.tier_level);
      v_granted := v_granted + t.reward_points;
    end if;
  end loop;
  update member_achievements set current_value=v_new, current_tier=greatest(current_tier,v_tier), last_period=p_period_key,
    status = case when v_tier>=v_max and v_max>0 then 'unlocked' when v_new>0 then 'in_progress' else 'locked' end,
    unlocked_at = case when v_tier>=v_max and v_max>0 and unlocked_at is null then now() else unlocked_at end,
    updated_at=now()
    where id=r.id;
  return jsonb_build_object('value',v_new,'tier',v_tier,'granted',v_granted);
end $$;

-- 釘選到個人展示櫃(榮耀炫耀;最多 3 枚,且須已解鎖)
create or replace function ach_pin_tx(p_member uuid, p_code text, p_on boolean)
returns jsonb language plpgsql as $$
declare v_org uuid; a achievements; r member_achievements; v_cnt int;
begin
  select org_id into v_org from members where id=p_member;
  select * into a from achievements where org_id=v_org and code=p_code and deleted_at is null;
  if not found then raise exception '成就不存在'; end if;
  select * into r from member_achievements where member_id=p_member and achievement_id=a.id for update;
  if not found or r.status<>'unlocked' then raise exception '尚未解鎖,不能釘選'; end if;
  if p_on then
    select count(*) into v_cnt from member_achievements where member_id=p_member and pinned;
    if v_cnt >= 3 and not r.pinned then raise exception '展示櫃最多 3 枚'; end if;
  end if;
  update member_achievements set pinned=p_on, updated_at=now() where id=r.id;
  return jsonb_build_object('code',p_code,'pinned',p_on);
end $$;

-- ============================================================
-- SEED:65 個成就(對齊 v2.0 主清單)。改 v_org 為你的 org_id。
-- ============================================================
do $$
declare v_org uuid;
begin
  select id into v_org from orgs order by created_at limit 1;  -- 或直接指定你的 org_id
  if v_org is null then raise exception '找不到 org,請先建立 org 或指定 v_org'; end if;

  insert into achievements(org_id,code,name,struct,is_hidden,motivation,flavor,condition_text,grants_title,is_signature,reward_points,sort,is_active) values
  (v_org,'self_draw_queen','自摸女王','specific',false,'competition','mahjong','單局自摸胡牌',null,false,50,0,true),
  (v_org,'men_qing_self','門清自摸','specific',false,'competition','mahjong','門清自摸胡',null,false,50,10,true),
  (v_org,'big_three','大三元','specific',false,'competition','mahjong','胡出大三元',null,false,80,20,true),
  (v_org,'small_four','小四喜','specific',false,'competition','mahjong','胡出小四喜',null,false,80,30,true),
  (v_org,'all_honors','字一色','specific',false,'competition','mahjong','胡出字一色',null,false,80,40,true),
  (v_org,'sea_moon','海底撈月','specific',false,'competition','mahjong','海底牌自摸胡',null,false,50,50,true),
  (v_org,'kong_bloom','槓上開花','specific',false,'competition','mahjong','開槓補牌自摸胡',null,false,50,60,true),
  (v_org,'dealer_three','連莊三響','specific',false,'competition','mahjong','連續連莊 3 次',null,false,50,70,true),
  (v_org,'migi','MIGI','cumulative',false,'competition','mahjong','達成「咪幾」— 開局極罕見的胡牌/聽牌(品牌同名絕技)','MIGI',true,0,80,true),
  (v_org,'heaven_win','天胡錦鯉','specific',false,'completion','luck','莊家起手天胡',null,false,80,90,true),
  (v_org,'eight_flowers','八仙過海','specific',false,'completion','luck','單局湊滿 8 花',null,false,50,100,true),
  (v_org,'flower_bloom','花開富貴','specific',false,'completion','luck','單局連續補花 ≥3',null,false,50,110,true),
  (v_org,'four_kong','一槓到底','specific',false,'completion','luck','單局開槓 4 次',null,false,50,120,true),
  (v_org,'daily_champ','常勝錦鯉','specific',false,'competition','luck','單日場場第一(≥3場)',null,false,50,130,true),
  (v_org,'first_topup','招財進寶','specific',false,'completion','wealth','首次儲值',null,false,50,140,true),
  (v_org,'birthday_gift','開運紅包','specific',false,'completion','wealth','領取生日禮',null,false,50,150,true),
  (v_org,'max_topup','儲值錦鯉','specific',false,'completion','wealth','單次儲值達最高檔',null,false,50,160,true),
  (v_org,'triple_service','滿堂彩','specific',false,'completion','wealth','單日用到場地+餐飲+派車',null,false,50,170,true),
  (v_org,'bestie_squad','閨蜜成團','specific',false,'social','girls','閨蜜日與 3 位好友同桌',null,false,50,180,true),
  (v_org,'sister_call','姐妹召集令','specific',false,'social','girls','推薦 3 位好友入會',null,false,80,190,true),
  (v_org,'all_girls_table','一桌都是姐妹','specific',false,'social','girls','整桌四人全女生',null,false,50,200,true),
  (v_org,'today_mvp','今日 MVP','specific',false,'competition','girls','女生場單場第一名',null,false,50,210,true),
  (v_org,'flagship_first','旗艦初登場','specific',false,'exploration','bear','首次踏進旗艦店',null,false,50,220,true),
  (v_org,'event_rookie','賽事新星','specific',false,'competition','bear','首次報名 MIGI 盃',null,false,50,230,true),
  (v_org,'all_store_conquer','開疆小熊','specific',false,'exploration','bear','集滿全分店打卡(全制霸)',null,false,200,240,true),
  (v_org,'hundred_battles','百戰雀士','cumulative',false,'competition','mahjong','累積勝場',null,false,0,250,true),
  (v_org,'lucky_draw','翻牌好手氣','cumulative',false,'collection','luck','摸牌抽中稀有次數',null,false,0,260,true),
  (v_org,'treasure_bowl','聚寶盆','cumulative',false,'completion','wealth','累積儲值額(點)',null,false,0,270,true),
  (v_org,'coupon_hunter','折價券獵人','cumulative',false,'completion','wealth','累積使用優惠券(張)',null,false,0,280,true),
  (v_org,'dessert_hunter','發財糕點控','cumulative',false,'exploration','wealth','嚐過甜點款式',null,false,0,290,true),
  (v_org,'big_spender','揮金一姐','cumulative',false,'completion','wealth','累積消費點數',null,false,0,300,true),
  (v_org,'pals_network','牌咖滿天下','cumulative',false,'social','girls','牌咖數',null,false,0,310,true),
  (v_org,'table_queen','揪桌女王','cumulative',false,'social','girls','成功揪滿桌數',null,false,0,320,true),
  (v_org,'social_butterfly','社交蝴蝶','cumulative',false,'social','girls','同桌不同人數',null,false,0,330,true),
  (v_org,'bring_newbie','帶新一姐','cumulative',false,'social','girls','帶新成桌次數',null,false,0,340,true),
  (v_org,'full_table','滿桌成局','cumulative',false,'social','girls','四人成局次數',null,false,0,350,true),
  (v_org,'bear_feeder','小熊餵養師','cumulative',false,'collection','bear','小熊養成等級',null,false,0,360,true),
  (v_org,'bear_dressup','小熊變裝秀','cumulative',false,'collection','bear','收集裝扮套數',null,false,0,370,true),
  (v_org,'five_store_tour','五店巡禮','cumulative',false,'exploration','bear','走訪不同分店',null,false,0,380,true),
  (v_org,'checkin_streak','招財貓上身','streak',false,'completion','wealth','連續簽到天數',null,false,0,390,true),
  (v_org,'weekly_perfect','全勤小熊','streak',false,'completion','bear','連續簽到滿 7 天(週全勤)',null,false,0,400,true),
  (v_org,'five_day_fortune','五路財神','streak',false,'completion','wealth','一週 5 天都有到店消費',null,false,0,410,true),
  (v_org,'monthly_date','月月有約','streak',false,'social','girls','連續月份到店',null,false,0,420,true),
  (v_org,'today_lucky','今日歐皇','streak',false,'competition','luck','當日連勝 3 場',null,false,0,430,true),
  (v_org,'win_streak','連勝旋風','streak',false,'competition','luck','最高連勝',null,false,0,440,true),
  (v_org,'no_deal_streak','不放槍連發','streak',false,'competition','mahjong','連續不放槍局數',null,false,0,450,true),
  (v_org,'bestie_revisit','閨蜜回訪','streak',false,'social','girls','與同一好友連續週同桌',null,false,0,460,true),
  (v_org,'night_bear','深夜小熊','specific',true,'exploration','bear','凌晨 2 點後仍在桌',null,false,80,470,true),
  (v_org,'morning_bear','晨型小熊','specific',true,'exploration','bear','開店首小時到店',null,false,80,480,true),
  (v_org,'no_false_win','詐胡絕緣體','cumulative',true,'completion','mahjong','連續 50 局零詐胡',null,false,0,490,true),
  (v_org,'rainy_player','雨天雀士','specific',true,'exploration','bear','下雨天仍到店打牌',null,false,80,500,true),
  (v_org,'birthday_play','生日這天打','specific',true,'social','girls','生日當天到店開桌',null,false,80,510,true),
  (v_org,'three_gen_table','三代同桌','specific',true,'social','girls','同桌跨三個會員等級',null,false,80,520,true),
  (v_org,'season_jin','本季雀神','prestige',false,'prestige','mahjong','單季全店第一','本季雀神',false,500,530,true),
  (v_org,'girls_jin','女子組雀神','prestige',false,'prestige','girls','女子榜單季第一','女子組雀神',false,500,540,true),
  (v_org,'hall_bear','名人堂之熊','prestige',false,'prestige','bear','登上歷代雀神名人堂','名人堂',false,300,550,true),
  (v_org,'hall_triple','名人堂三冠','prestige',false,'prestige','mahjong','名人堂累積 3 屆','三屆雀神',false,800,560,true),
  (v_org,'defender','衛冕者','prestige',false,'prestige','mahjong','連續 2 季保住雀神','衛冕雀神',false,600,570,true),
  (v_org,'top100','全店百大','prestige',false,'prestige','mahjong','進全店排名前 100','全店百大',false,200,580,true),
  (v_org,'store_flower','店花','prestige',false,'prestige','girls','單月單店出席/消費榜第一','店花',false,300,590,true),
  (v_org,'rare_hunter','稀有獵手','prestige',false,'prestige','luck','持有任一稀有度 <5% 徽章','稀有獵手',false,200,600,true),
  (v_org,'store_treasure','鎮店之寶','prestige',false,'prestige','bear','小熊養成達最高 Lv 並公開展示','鎮店之寶',false,300,610,true),
  (v_org,'founding_member','開幕元老','prestige',false,'prestige','wealth','某店開幕首週入會','開幕元老',false,300,620,true)
  on conflict do nothing;

  insert into achievement_tiers(org_id,achievement_id,tier_level,tier_name,threshold,reward_points)
  select v_org, a.id, t.lvl, t.nm, t.th, t.pts
  from achievements a
  join (values
    ('migi',1,'I',1,100),
    ('migi',2,'II',3,200),
    ('migi',3,'III',5,300),
    ('migi',4,'IV',10,500),
    ('hundred_battles',1,'I',100,100),
    ('hundred_battles',2,'II',500,300),
    ('hundred_battles',3,'III',1000,600),
    ('hundred_battles',4,'IV',5000,1200),
    ('lucky_draw',1,'I',1,100),
    ('lucky_draw',2,'II',5,300),
    ('lucky_draw',3,'III',10,700),
    ('treasure_bowl',1,'I',10000,100),
    ('treasure_bowl',2,'II',50000,300),
    ('treasure_bowl',3,'III',100000,700),
    ('coupon_hunter',1,'I',5,100),
    ('coupon_hunter',2,'II',20,300),
    ('coupon_hunter',3,'III',50,700),
    ('dessert_hunter',1,'I',5,100),
    ('dessert_hunter',2,'II',15,300),
    ('dessert_hunter',3,'III',30,700),
    ('big_spender',1,'I',10000,100),
    ('big_spender',2,'II',50000,300),
    ('big_spender',3,'III',200000,700),
    ('pals_network',1,'I',5,100),
    ('pals_network',2,'II',20,300),
    ('pals_network',3,'III',50,700),
    ('table_queen',1,'I',3,100),
    ('table_queen',2,'II',10,300),
    ('table_queen',3,'III',30,700),
    ('social_butterfly',1,'I',20,100),
    ('social_butterfly',2,'II',50,300),
    ('social_butterfly',3,'III',100,700),
    ('bring_newbie',1,'I',1,100),
    ('bring_newbie',2,'II',5,300),
    ('bring_newbie',3,'III',15,700),
    ('full_table',1,'I',10,100),
    ('full_table',2,'II',50,300),
    ('full_table',3,'III',200,700),
    ('bear_feeder',1,'I',10,100),
    ('bear_feeder',2,'II',20,300),
    ('bear_feeder',3,'III',50,700),
    ('bear_dressup',1,'I',3,100),
    ('bear_dressup',2,'II',8,300),
    ('bear_dressup',3,'III',15,700),
    ('five_store_tour',1,'I',3,100),
    ('five_store_tour',2,'II',5,300),
    ('five_store_tour',3,'III',10,700),
    ('checkin_streak',1,'I',7,100),
    ('checkin_streak',2,'II',30,300),
    ('checkin_streak',3,'III',100,700),
    ('weekly_perfect',1,'I',7,300),
    ('five_day_fortune',1,'I',5,300),
    ('monthly_date',1,'I',3,100),
    ('monthly_date',2,'II',6,300),
    ('monthly_date',3,'III',12,700),
    ('today_lucky',1,'I',3,300),
    ('win_streak',1,'I',3,100),
    ('win_streak',2,'II',5,300),
    ('win_streak',3,'III',10,700),
    ('no_deal_streak',1,'I',20,100),
    ('no_deal_streak',2,'II',50,300),
    ('no_deal_streak',3,'III',100,700),
    ('bestie_revisit',1,'I',3,300),
    ('no_false_win',1,'I',50,300)
  ) as t(code,lvl,nm,th,pts) on t.code = a.code
  where a.org_id = v_org
  on conflict do nothing;
end $$;

-- ---------- MIGI 殿堂(達成咪幾者專屬榮譽牆;純展示,零成本,不算獎品) ----------
create or replace view v_migi_hall as
  select ma.org_id, ma.member_id, ma.current_value as migi_count, ma.current_tier, ma.unlocked_at
  from member_achievements ma
  join achievements a on a.id = ma.achievement_id and a.code = 'migi'
  where ma.status = 'unlocked';   -- 達成 IV 級(咪幾 ×10)才入殿堂
-- 顯示時 join members 取暱稱;建議排序 migi_count desc, unlocked_at asc。RLS 由 member_achievements 的 select policy 帶入。

-- ============================================================
-- 閉環:事件層呼叫 ach_unlock_tx / ach_progress_tx / ach_streak_tx
--   → 解級時 grant_points_tx 贈點(bonus)→ 會員錢包。
--   榮耀型由季/月排名 job 呼叫 ach_unlock_tx 並指派 grants_title。
--   限時型設 valid_from/valid_to,過期 _ach_live=false 自動停止計算。
-- ============================================================
