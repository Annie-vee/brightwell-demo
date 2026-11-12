-- Brightwell Premium Plan Simulation (fictional data only)
-- Run once in Supabase > SQL Editor. Safe to re-run only on an empty project.
create extension if not exists pg_cron;
create schema if not exists private;

-- ---------- tables ----------
create table staff(staff_id text primary key, hospital text not null, role text not null,
  cohort text not null check (cohort in ('Existing','Incoming')));
create table courses(id int primary key, title text not null, requires_cert boolean not null default true);
create table assignments(id serial primary key, staff_id text references staff, course_id int references courses,
  due_date date not null,
  status text not null default 'not_started' check (status in ('not_started','in_progress','completed')),
  completed_on date,
  cert_status text not null default 'n/a' check (cert_status in ('n/a','missing','awaiting','verified','rejected')),
  cert_ref text, submitted_by text, updated_at timestamptz default now(), unique(staff_id,course_id));
create table issues(id serial primary key, assignment_id int references assignments on delete cascade,
  type text check (type in ('incomplete','overdue','cert')),
  status text default 'flagged' check (status in ('flagged','under_review','resolved','reopened')),
  reviewer text, updated_at timestamptz default now(), unique(assignment_id,type));
create table actions(id serial primary key, at timestamptz default now(), actor text, role text,
  action text, assignment_id int, detail text);
create table report_runs(id serial primary key, run_at timestamptz default now(), kind text, period text,
  outcome text, exception_count int, csv text, error text);
create table settings(key text primary key, value text);
create table profiles(id uuid primary key references auth.users on delete cascade, email text,
  role text not null default 'learner' check (role in ('learner','ld','compliance','executive')),
  staff_id text default 'CV-001');

-- new Google sign-ins get a learner profile; use the in-app demo switcher to change role
create function private.new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,email) values(new.id,new.email); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.new_user();

-- ---------- helpers ----------
create function public.my_role() returns text language sql stable security definer set search_path=public as
$$ select role from profiles where id=auth.uid() $$;
create function public.my_staff() returns text language sql stable security definer set search_path=public as
$$ select staff_id from profiles where id=auth.uid() $$;
create function public.who() returns text language sql stable security definer set search_path=public as
$$ select email from profiles where id=auth.uid() $$;

create function private.log(p_actor text,p_role text,p_action text,p_aid int,p_detail text) returns void
language sql security definer set search_path=public as
$$ insert into actions(actor,role,action,assignment_id,detail) values(p_actor,p_role,p_action,p_aid,p_detail) $$;

-- ---------- automatic issue checks (runs on every record change + every hour via cron) ----------
-- incomplete: not completed and due within 30 days (or past due) | overdue: not completed and past due
-- cert: completed but certificate is missing / awaiting verification / rejected
create function private.scan_assignment(a_id int) returns void language plpgsql security definer set search_path=public as $$
declare a assignments; t text; want boolean;
begin
  select * into a from assignments where id=a_id;
  foreach t in array array['incomplete','overdue','cert'] loop
    want := case t
      when 'incomplete' then a.status<>'completed' and a.due_date<=current_date+30
      when 'overdue'    then a.status<>'completed' and a.due_date<current_date
      else a.cert_status in ('missing','awaiting','rejected') end;
    if want then
      insert into issues(assignment_id,type) values(a.id,t) on conflict do nothing;
      if found then perform private.log('system','system','Auto-flagged',a.id,t); end if;
      update issues set status='reopened',updated_at=now() where assignment_id=a.id and type=t and status='resolved';
      if found then perform private.log('system','system','Reopened',a.id,t); end if;
    else
      update issues set status='resolved',updated_at=now() where assignment_id=a.id and type=t and status<>'resolved';
      if found then perform private.log('system','system','Resolved: condition fixed',a.id,t); end if;
    end if;
  end loop;
end $$;

create function private.trg() returns trigger language plpgsql security definer set search_path=public as
$$ begin perform private.scan_assignment(new.id); return null; end $$;
create trigger scan_on_change after insert or update on assignments for each row execute function private.trg();

create function private.scan_all() returns void language plpgsql security definer set search_path=public as
$$ declare r int; begin for r in select id from assignments loop perform private.scan_assignment(r); end loop; end $$;

-- ---------- report builder (CSV is stored as text, so saved snapshots never change) ----------
create function private.build_report(k text, fail boolean default false) returns int
language plpgsql security definer set search_path=public as $$
declare v_csv text; n int; rid int;
  d date := (now() at time zone 'America/New_York')::date;
  p text := to_char((now() at time zone 'America/New_York')::date-6,'YYYY-MM-DD')||' to '||to_char((now() at time zone 'America/New_York')::date,'YYYY-MM-DD');
begin
  begin
    if fail then raise exception 'Simulated failure: could not read training records'; end if;
    with r as (
      select s.staff_id,s.hospital,s.role,s.cohort,c.title,a.due_date,a.status,a.completed_on,a.cert_status,
        coalesce((select string_agg(case i.type when 'overdue' then 'Overdue' when 'incomplete' then 'Incomplete training'
            else case a.cert_status when 'missing' then 'Missing certificate' when 'awaiting' then 'Awaiting verification'
            else 'Rejected certificate' end end,'; ' order by i.type)
          from issues i where i.assignment_id=a.id and i.status<>'resolved'),'') ex
      from assignments a join staff s on s.staff_id=a.staff_id join courses c on c.id=a.course_id)
    select count(*) filter (where ex<>''),
      E'DEMONSTRATION REPORT — NOT REGULATOR APPROVED\nReport period,'||p||E'\nGenerated at,'||now()::text||E'\nRun type,'||k||
      E'\nsection,staff_id,facility,role,cohort,course,due_date,course_status,completion_date,certificate_status,exceptions\n'||
      coalesce(string_agg(concat_ws(',',
        case when ex<>'' then 'EXCEPTION' when cert_status='verified' then 'VERIFIED' else 'OTHER' end,
        staff_id,hospital,role,cohort,title,due_date::text,status,coalesce(completed_on::text,''),cert_status,ex),
        E'\n' order by ex='', staff_id, title),'')
    into n, v_csv from r;
    insert into report_runs(kind,period,outcome,exception_count,csv) values(k,p,'success',n,v_csv) returning id into rid;
  exception when others then
    insert into report_runs(kind,period,outcome,error) values(k,p,'failed',sqlerrm) returning id into rid;
  end;
  return rid;
end $$;

-- hourly tick: scan records; on Friday at the configured Ohio hour, run the report once (DST-safe)
create function private.friday_tick() returns void language plpgsql security definer set search_path=public as $$
declare ny timestamp := now() at time zone 'America/New_York';
begin
  perform private.scan_all();
  if extract(dow from ny)=5
     and extract(hour from ny)=(select value::int from settings where key='report_hour')
     and not exists(select 1 from report_runs where kind='scheduled' and (run_at at time zone 'America/New_York')::date=ny::date)
  then perform private.build_report('scheduled'); end if;
end $$;
select cron.schedule('brightwell-hourly-tick','0 * * * *','select private.friday_tick()');

-- ---------- app actions (every one checks the caller's role inside the database) ----------
create function public.demo_set_role(p_role text, p_staff text default 'CV-001') returns void
language plpgsql security definer set search_path=public as $$
begin
  if (select value from settings where key='demo_mode')<>'on' then raise exception 'Demo role switching is off'; end if;
  update profiles set role=p_role, staff_id=p_staff where id=auth.uid();
end $$;

create function public.complete_training(p_id int) returns void language plpgsql security definer set search_path=public as $$
declare a assignments;
begin
  select * into a from assignments where id=p_id;
  if not (my_role() in ('ld','compliance') or (my_role()='learner' and a.staff_id=my_staff())) then
    raise exception 'Not permitted: your role cannot update this training record'; end if;
  update assignments set status='completed', completed_on=current_date, updated_at=now(),
    cert_status=case when (select requires_cert from courses where id=a.course_id) then 'missing' else 'n/a' end where id=p_id;
  perform private.log(who(),my_role(),'Training marked completed',p_id,null);
end $$;

create function public.upload_certificate(p_id int, p_ref text) returns void language plpgsql security definer set search_path=public as $$
declare a assignments;
begin
  if my_role() not in ('ld','compliance') then raise exception 'Not permitted: your role cannot upload certificates'; end if;
  select * into a from assignments where id=p_id;
  if a.status<>'completed' then raise exception 'Course is not completed'; end if;
  update assignments set cert_ref=p_ref, cert_status='awaiting', submitted_by=who(), updated_at=now() where id=p_id;
  update issues set status='under_review', updated_at=now() where assignment_id=p_id and type='cert' and status<>'resolved';
  perform private.log(who(),my_role(),'Certificate uploaded (awaiting verification)',p_id,p_ref);
end $$;

create function public.verify_certificate(p_id int, p_approve boolean) returns void language plpgsql security definer set search_path=public as $$
declare a assignments;
begin
  if my_role()<>'compliance' then raise exception 'Blocked: only Compliance (Lisa) can verify or reject certificates'; end if;
  select * into a from assignments where id=p_id;
  if a.cert_status<>'awaiting' then raise exception 'Certificate is not awaiting verification'; end if;
  if p_approve then
    if position(a.staff_id in coalesce(a.cert_ref,''))=0 then
      raise exception 'Cannot verify: certificate does not match this employee'; end if;
    update assignments set cert_status='verified', updated_at=now() where id=p_id;   -- trigger resolves the issue
    update issues set reviewer=who() where assignment_id=p_id and type='cert';
    perform private.log(who(),my_role(),'Certificate verified',p_id,a.cert_ref);
  else
    update assignments set cert_status='rejected', updated_at=now() where id=p_id;
    update issues set status='reopened', reviewer=who(), updated_at=now() where assignment_id=p_id and type='cert';
    perform private.log(who(),my_role(),'Certificate rejected',p_id,a.cert_ref);
  end if;
end $$;

create function public.start_review(p_issue int) returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('ld','compliance') then raise exception 'Not permitted: your role cannot review issues'; end if;
  update issues set status='under_review', reviewer=who(), updated_at=now() where id=p_issue and status in ('flagged','reopened');
  perform private.log(who(),my_role(),'Issue under review',(select assignment_id from issues where id=p_issue),null);
end $$;

create function public.run_scan() returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('ld','compliance') then raise exception 'Not permitted'; end if;
  perform private.scan_all();
end $$;

create function public.run_report_now() returns int language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('ld','compliance') then raise exception 'Not permitted: your role cannot run reports'; end if;
  return private.build_report('manual');
end $$;

create function public.simulate_friday(p_fail boolean default false) returns int language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('ld','compliance') then raise exception 'Not permitted'; end if;
  return private.build_report('scheduled (test)', p_fail);
end $$;

create function public.get_stats(p_h text default null,p_r text default null,p_c text default null) returns json
language plpgsql security definer set search_path=public as $$
declare res json;
begin
  if my_role() not in ('ld','compliance','executive') then raise exception 'Not permitted'; end if;
  with f as (select a.*, s.hospital from assignments a join staff s on s.staff_id=a.staff_id
             where (p_h is null or s.hospital=p_h) and (p_r is null or s.role=p_r) and (p_c is null or s.cohort=p_c)),
       iss as (select i.status from issues i join f on f.id=i.assignment_id)
  select json_build_object(
    'total',(select count(*) from f),
    'completed',(select count(*) from f where status='completed'),
    'overdue',(select count(*) from f where status<>'completed' and due_date<current_date),
    'missing',(select count(*) from f where cert_status='missing'),
    'awaiting',(select count(*) from f where cert_status='awaiting'),
    'verified',(select count(*) from f where cert_status='verified'),
    'rejected',(select count(*) from f where cert_status='rejected'),
    'open',(select count(*) from iss where status<>'resolved'),
    'resolved',(select count(*) from iss where status='resolved'),
    'by_hospital',(select coalesce(json_agg(x),'[]'::json) from (
        select hospital, count(*) total, count(*) filter (where status='completed') completed,
               count(*) filter (where cert_status='verified') verified, count(*) filter (where cert_status='missing') missing
        from f group by hospital order by hospital) x)) into res;
  return res;
end $$;

-- ---------- row-level security: reads only; all writes go through the functions above ----------
alter table staff enable row level security;       alter table courses enable row level security;
alter table assignments enable row level security; alter table issues enable row level security;
alter table actions enable row level security;     alter table report_runs enable row level security;
alter table settings enable row level security;    alter table profiles enable row level security;
create policy r on profiles    for select using (id=auth.uid());
create policy r on courses     for select using (auth.uid() is not null);
create policy r on settings    for select using (auth.uid() is not null);
create policy r on staff       for select using (my_role() in ('ld','compliance') or (my_role()='learner' and staff_id=my_staff()));
create policy r on assignments for select using (my_role() in ('ld','compliance') or (my_role()='learner' and staff_id=my_staff()));
create policy r on issues      for select using (my_role() in ('ld','compliance'));
create policy r on actions     for select using (my_role() in ('ld','compliance'));
create policy r on report_runs for select using (my_role() in ('ld','compliance','executive'));
revoke insert,update,delete on all tables in schema public from anon, authenticated;

-- ---------- invented sample data: 48 staff, 3 facilities, 4 courses ----------
insert into settings values ('report_hour','17'),('demo_mode','on');   -- 17 = 5 pm Ohio time
insert into courses values (1,'Infection Control',true),(2,'Basic Life Support',true),(3,'Patient Privacy',true),(4,'Medication Safety',true);
insert into staff
select v.p||'-'||lpad(n::text,3,'0'), v.h,
  (array['Technician','Administrator','Nurse','Nurse','Physician'])[1+(n%5)], v.co
from (values ('CV','Cedar Valley Medical Center','Existing',20),('LG','Lakeside General','Incoming',14),
             ('RV','Ridgeview Community','Incoming',14)) v(p,h,co,cnt)
cross join lateral generate_series(1,v.cnt) n;

insert into assignments(staff_id,course_id,due_date,status,completed_on,cert_status,cert_ref)
select staff_id, course_id, due, st, case when st='completed' then current_date-2 end,
  case when st<>'completed' then 'n/a' when k in (0,1) then 'verified' when k=2 then 'awaiting' else 'missing' end,
  case when st='completed' and k<3 then staff_id||'_C'||course_id||'.pdf' end
from (
  select s.staff_id, c.id course_id, kk.k,
    case when s.cohort='Incoming' then date '2027-06-30' else current_date+(((s.n+c.id*5)%30)-12) end due,
    case when kk.k<=3 then 'completed' when kk.k=4 then 'in_progress' else 'not_started' end st
  from (select *, right(staff_id,3)::int n from staff) s
  join courses c on c.id in (1+(s.n%4), 1+((s.n+1)%4))
  cross join lateral (select (s.n*3+c.id)%7 as k) kk) q;

-- the two story records
update assignments set status='completed', completed_on=current_date-2, cert_status='missing', cert_ref=null,
  due_date=current_date+3 where staff_id='CV-017' and course_id=2;            -- completed, certificate missing
update assignments set status='in_progress', completed_on=null, cert_status='n/a', cert_ref=null,
  due_date=current_date-5 where staff_id='CV-005' and course_id=2;            -- stays overdue after the fix
