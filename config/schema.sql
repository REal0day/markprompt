-- Extensions
create extension if not exists vector with schema public;
create extension if not exists pgroonga with schema public;

-- Users
create table users (
  id                           uuid references auth.users on delete cascade not null primary key,
  updated_at                   timestamp with time zone,
  full_name                    text,
  email                        text unique not null,
  avatar_url                   text,
  has_completed_onboarding     boolean not null default false,
  subscribe_to_product_updates boolean not null default false,
  outreach_tag                 text
);

-- Teams
create table public.teams (
  id                  uuid primary key default uuid_generate_v4(),
  inserted_at         timestamp with time zone default timezone('utc'::text, now()) not null,
  slug                text not null unique,
  name                text,
  is_personal         boolean default false,
  stripe_customer_id  text,
  stripe_price_id     text,
  is_enterprise_plan  boolean,
  plan_details        jsonb,
  billing_cycle_start timestamp with time zone,
  created_by          uuid references public.users not null
);
comment on table public.teams is 'Teams data.';

-- Projects
create table public.projects (
  id                  uuid primary key default uuid_generate_v4(),
  inserted_at         timestamp with time zone default timezone('utc'::text, now()) not null,
  slug                text not null,
  name                text not null,
  public_api_key      text not null unique,
  private_dev_api_key text not null unique,
  openai_key          text,
  github_repo         text,
  team_id             uuid references public.teams on delete cascade not null,
  is_starter          boolean not null default false,
  created_by          uuid references public.users not null
);
comment on table public.projects is 'Projects within a team.';

-- Sources
create type source_type as enum ('github', 'motif', 'website', 'file-upload', 'api-upload');

create table public.sources (
  id          uuid primary key default uuid_generate_v4(),
  inserted_at timestamp with time zone default timezone('utc'::text, now()) not null,
  project_id  uuid references public.projects on delete cascade not null,
  type        source_type not null,
  data        jsonb
);
comment on table public.sources is 'Data sources for a project.';

-- Memberships
create type membership_type as enum ('viewer', 'admin');

create table public.memberships (
  id            uuid primary key default uuid_generate_v4(),
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  user_id       uuid references public.users not null,
  team_id       uuid references public.teams not null,
  type          membership_type not null
);
comment on table public.memberships is 'Memberships of a user in a team.';

-- Domains
create table public.domains (
  id            bigint generated by default as identity primary key,
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  name          text not null unique,
  project_id    uuid references public.projects on delete cascade not null
);
comment on table public.domains is 'Domains associated to a project.';

-- Tokens
create table public.tokens (
  id            bigint generated by default as identity primary key,
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  value         text not null,
  project_id    uuid references public.projects on delete cascade not null,
  created_by    uuid references public.users not null
);
comment on table public.tokens is 'Tokens associated to a project.';

-- Files
create table public.files (
  id          bigint generated by default as identity primary key,
  path        text not null,
  meta        jsonb,
  checksum    text,
  source_id   uuid references public.sources on delete cascade not null,
  updated_at  timestamp with time zone default timezone('utc'::text, now()) not null
);

-- File sections
create table public.file_sections (
  id            bigint generated by default as identity primary key,
  file_id       bigint not null references public.files on delete cascade,
  content       text,
  token_count   int,
  meta          jsonb,
  embedding     vector(1536),
  -- Computed fields
  cf_file_meta  jsonb,
  cf_project_id uuid references public.projects
);

-- Access tokens
create table public.user_access_tokens (
  id                       bigint generated by default as identity primary key,
  user_id                  uuid not null references public.users on delete cascade,
  provider                 text,
  access_token             text,
  expires                  bigint,
  refresh_token            text,
  refresh_token_expires    bigint,
  state                    text,
  scope                    text,
  meta                     jsonb
);

-- Prompt configs
create table public.prompt_configs (
  id                  uuid primary key default uuid_generate_v4(),
  created_at          timestamp with time zone default timezone('utc'::text, now()) not null,
  project_id          uuid references public.projects on delete cascade not null,
  share_key           text,
  config              jsonb
);
comment on table public.prompt_configs is 'Prompt configs.';

-- Query stats

create table public.query_stats (
  id              uuid primary key default uuid_generate_v4(),
  created_at      timestamp with time zone default timezone('utc'::text, now()) not null,
  project_id      uuid references public.projects on delete cascade not null,
  prompt          text,
  response        text,
  meta            jsonb,
  no_response     boolean,
  upvoted         boolean,
  downvoted       boolean,
  processed       boolean not null default false,
  embedding       vector(1536)
);
comment on table public.query_stats is 'Query stats.';

-- Functions

create function public.handle_new_user()
returns trigger as $$
begin
  insert into public.users (id, full_name, email, avatar_url)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'email', new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$ language plpgsql security definer;

create or replace function match_file_sections(
  project_id uuid,
  embedding vector(1536),
  match_threshold float,
  match_count int,
  min_content_length int)
returns table (
  path text,
  content text,
  token_count int,
  similarity float,
  source_type source_type,
  source_data jsonb
)
language plpgsql
as $$
#variable_conflict use_variable
begin
  return query
  select
    files.path,
    file_sections.content,
    file_sections.token_count,
    (file_sections.embedding <#> embedding) * -1 as similarity,
    sources.type as source_type,
    sources.data as source_data
  from file_sections
  join files on file_sections.file_id = files.id
  join sources on files.source_id = sources.id
  where sources.project_id = project_id
  -- We only care about sections that have a useful amount of content
  and length(file_sections.content) >= min_content_length
  -- The dot product is negative because of a Postgres limitation,
  -- so we negate it
  and (file_sections.embedding <#> embedding) * -1 > match_threshold
  -- OpenAI embeddings are normalized to length 1, so
  -- cosine similarity and dot product will produce the same results.
  -- Using dot product which can be computed slightly faster.
  -- For the different syntaxes, see https://github.com/pgvector/pgvector
  order by file_sections.embedding <#> embedding
  limit match_count;
end;
$$;

-- FTS

create or replace function fts(
  search_term text,
  match_count int,
  project_id uuid
)
returns table (
  id bigint,
  content text,
  meta jsonb,
  file_id bigint,
  file_meta jsonb
)
language plpgsql
as $$
begin
  return query
  select
    fs.id,
    fs.content,
    fs.meta,
    fs.file_id as file_id,
    fs.cf_file_meta as file_meta
  from file_sections fs
  where
    fs.cf_project_id = fts.project_id
    and (
      array[
        (fs.cf_file_meta->>'title')::text,
        (fs.meta->'leadHeading'->>'value')::text,
        fs.content
      ] &@ (fts.search_term, array[100, 10, 1], 'idx_file_sections_fts')::pgroonga_full_text_search_condition
    )
  limit match_count;
end;
$$;

create or replace function fts_metadata(
  file_id bigint
)
returns table (
  id bigint,
  content text,
  meta jsonb,
  file_id bigint,
  file_meta jsonb
)
language plpgsql
as $$
begin
  return query
  select
    fs.id,
    fs.content,
    fs.meta,
    fs.file_id as file_id,
    fs.cf_file_meta as file_meta
  from file_sections fs
  where
    fs.cf_project_id = fts.project_id
    and (
      array[
        (fs.cf_file_meta->>'title')::text,
        (fs.meta->'leadHeading'->>'value')::text,
        fs.content
      ] &@ (fts.search_term, array[100, 10, 1], 'idx_file_sections_fts')::pgroonga_full_text_search_condition
    )
  limit match_count;
end;
$$;

-- Query stats top references

create or replace function query_stats_top_references(
  project_id uuid,
  from_tz timestamptz,
  to_tz timestamptz,
  match_count int
)
returns table (
  path text,
  source_type text,
  source_data jsonb,
  occurrences bigint
)
language plpgsql
as $$
begin
  return query
  select
    reference->>'path' as path,
    reference->'source'->>'type' as source_type,
    reference->'source'->'data' as source_data,
    count(*) as occurrences
  from query_stats,
    jsonb_array_elements(meta->'references') as reference
  where
    query_stats.project_id = query_stats_top_references.project_id
    and query_stats.created_at >= query_stats_top_references.from_tz
    and query_stats.created_at <= query_stats_top_references.to_tz
    and reference->>'path' is not null
    and reference->'source'->>'type' is not null
  group by path, source_data, source_type
  order by occurrences desc
  limit query_stats_top_references.match_count;
end;
$$;

-- Automatically compute the file meta
create or replace function update_file_sections_cf_file_meta()
returns trigger
language plpgsql
as $$
begin
  select meta into new.cf_file_meta from public.files where id = new.file_id;
  return new;
end;
$$;

-- Automatically compute the project id
create or replace function update_file_sections_cf_project_id()
returns trigger
language plpgsql
as $$
begin
  new.cf_project_id := (
    select s.project_id
    from sources s
    join files f on f.source_id = s.id
    where f.id = new.file_id
    limit 1
  );
  return new;
end;
$$;

-- Triggers

-- This trigger automatically creates a user entry when a new user signs up
-- via Supabase Auth.for more details.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- This trigger automatically adds the file meta to a file_section
create trigger trigger_update_file_sections_cf_file_meta
  before insert or update on public.file_sections
  for each row
  execute function update_file_sections_cf_file_meta();

-- This trigger automatically adds the project id to a file_section
create trigger trigger_update_file_sections_cf_project_id
  before insert or update on public.file_sections
  for each row
  execute function update_file_sections_cf_project_id();

-- Views

create view v_team_project_usage_info as
  select
    projects.id as project_id,
    teams.id as team_id,
    teams.is_enterprise_plan as is_enterprise_plan,
    teams.stripe_price_id as stripe_price_id,
    teams.plan_details as plan_details,
    sum(file_sections.token_count) as team_token_count
  from file_sections
  left join files on file_sections.file_id = files.id
  left join sources on files.source_id = sources.id
  left join projects on sources.project_id = projects.id
  left join teams on projects.team_id = teams.id
  group by projects.id, teams.id;

create view v_team_project_info as
  select
    projects.id as project_id,
    teams.id as team_id,
    teams.is_enterprise_plan as is_enterprise_plan,
    teams.stripe_price_id as stripe_price_id,
    teams.plan_details as plan_details
  from projects
  left join teams on projects.team_id = teams.id;

create view v_file_section_search_infos as
  select
    f.id as file_id,
    f.path as file_path,
    f.meta as file_meta,
    fs.content as section_content,
    fs.meta as section_meta,
    s.type as source_type,
    s.data as source_data,
    p.id as project_id,
    p.public_api_key as public_api_key,
    p.private_dev_api_key as private_dev_api_key,
    tok.value as token,
    d.name as domain,
    t.stripe_price_id as stripe_price_id,
    t.is_enterprise_plan as is_enterprise_plan
  from file_sections fs
  left join files f on fs.file_id = f.id
  left join sources s on f.source_id = s.id
  left join projects p on s.project_id = p.id
  left join tokens tok on p.id = tok.project_id
  left join domains d on p.id = d.project_id
  left join teams t on t.id = p.team_id;

create view v_distinct_unprocessed_query_stats_project_ids as
  select project_id, min(created_at) as min_created_at
  from query_stats
  where processed = false
  group by project_id
  order by min_created_at asc;

create view v_insights_query_histogram_hour as
select project_id, date_trunc('hour', created_at) as created_at, count(*) as count
from query_stats
group by created_at, project_id
order by created_at;

create view v_insights_query_histogram_day as
select project_id, date_trunc('day', created_at) as created_at, count(*) as count
from query_stats
group by created_at, project_id
order by created_at;

create view v_insights_query_histogram_week as
select project_id, date_trunc('week', created_at) as created_at, count(*) as count
from query_stats
group by created_at, project_id
order by created_at;

create view v_insights_query_histogram_month as
select project_id, date_trunc('month', created_at) as created_at, count(*) as count
from query_stats
group by created_at, project_id
order by created_at;

create view v_insights_query_histogram_year as
select project_id, date_trunc('year', created_at) as created_at, count(*) as count
from query_stats
group by created_at, project_id
order by created_at;

-- Indexes

create index idx_files_source_id on files(source_id);
create index idx_sources_project_id on sources(project_id);
create index idx_file_sections_file_id on file_sections(file_id);
create index idx_projects_team_id on projects(team_id);
create index idx_memberships_user_id on memberships(user_id);
create index idx_tokens_project_id on tokens(project_id);
create index idx_domain_project_id on domains(project_id);
create index idx_query_stats_project_id_created_at_processed on query_stats(project_id, created_at, processed);
create index idx_file_sections_fts
on file_sections
using pgroonga ((array[
    content,
    (cf_file_meta->>'title')::text,
    (meta->'leadHeading'->>'value')::text
  ]));

-- RLS

-- Users

alter table users
  enable row level security;

create policy "Users can only see themselves." on users
  for select using (auth.uid() = id);

create policy "Users can insert their own user." on users
  for insert with check (auth.uid() = id);

create policy "Users can update own user." on users
  for update using (auth.uid() = id);

-- Memberships

alter table memberships
  enable row level security;

create policy "Users can only see their own memberships." on public.memberships
  for select using (auth.uid() = user_id);

create policy "Users can insert memberships they belong to." on public.memberships
  for insert with check (auth.uid() = user_id);

create policy "Users can update their own memberships." on public.memberships
  for update using (auth.uid() = user_id);

create policy "Users can delete their own memberships." on public.memberships
  for delete using (auth.uid() = user_id);

-- Teams

alter table teams
  enable row level security;

create policy "Users can only see teams they are members of." on public.teams
  for select using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = teams.id
    )
  );

-- Note: when a user creates a team, they are not yet members. So they should
-- just be able to create teams with no limitations
create policy "Users can insert teams." on public.teams
  for insert with check (true);

create policy "Users can update teams they are members of." on public.teams
  for update using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = teams.id
    )
  );

create policy "Users can delete teams they are members of." on public.teams
  for delete using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = teams.id
    )
  );

-- Projects

alter table projects
  enable row level security;

create policy "Users can only see projects associated to teams they are members of." on public.projects
  for select using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = projects.team_id
    )
  );

create policy "Users can insert projects associated to teams they are members of." on public.projects
  for insert with check (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = projects.team_id
    )
  );

create policy "Users can update projects associated to teams they are members of." on public.projects
  for update using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = projects.team_id
    )
  );

create policy "Users can delete projects associated to teams they are members of." on public.projects
  for delete using (
    exists (
      select 1 from memberships
      where memberships.user_id = auth.uid()
      and memberships.team_id = projects.team_id
    )
  );

-- Sources

alter table sources
  enable row level security;

create policy "Users can only see sources associated to projects they have access to." on public.sources
  for select using (
    sources.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert sources associated to projects they have access to." on public.sources
  for insert with check (
    sources.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can update sources associated to projects they have access to." on public.sources
  for update using (
    sources.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete sources associated to projects they have access to." on public.sources
  for delete using (
    sources.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

-- Files

alter table files
  enable row level security;

create policy "Users can only see files associated to sources associated to projects they have access to." on public.files
  for select using (
    files.source_id in (
      select sources.id from sources
      left join projects
      on sources.project_id = projects.id
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert files associated to sources associated to projects they have access to." on public.files
  for insert with check (
    files.source_id in (
      select sources.id from sources
      left join projects
      on sources.project_id = projects.id
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can update files associated to sources associated to projects they have access to." on public.files
  for update using (
    files.source_id in (
      select sources.id from sources
      left join projects
      on sources.project_id = projects.id
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete files associated to sources associated to projects they have access to." on public.files
  for delete using (
    files.source_id in (
      select sources.id from sources
      left join projects
      on sources.project_id = projects.id
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

-- File sections

-- No policies for file_sections: they are inaccessible to the client,
-- and only edited on the server with service_role access.

alter table file_sections
  enable row level security;

-- Prompt configs

alter table prompt_configs
  enable row level security;

create policy "Users can only see prompt configs associated to projects they have access to." on public.prompt_configs
  for select using (
    prompt_configs.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert prompt configs associated to projects they have access to." on public.prompt_configs
  for insert with check (
    prompt_configs.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can update prompt configs associated to projects they have access to." on public.prompt_configs
  for update using (
    prompt_configs.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete prompt configs associated to projects they have access to." on public.prompt_configs
  for delete using (
    prompt_configs.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

-- Tokens

alter table tokens
  enable row level security;

create policy "Users can only see tokens associated to projects they have access to." on public.tokens
  for select using (
    tokens.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert tokens associated to projects they have access to." on public.tokens
  for insert with check (
    tokens.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete tokens associated to projects they have access to." on public.tokens
  for delete using (
    tokens.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

-- Domains

alter table domains
  enable row level security;

create policy "Users can only see domains associated to projects they have access to." on public.domains
  for select using (
    domains.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert domains associated to projects they have access to." on public.domains
  for insert with check (
    domains.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete domains associated to projects they have access to." on public.domains
  for delete using (
    domains.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

-- User access tokens

alter table user_access_tokens
  enable row level security;

create policy "Users can only see their tokens." on user_access_tokens
  for select using (auth.uid() = user_id);

create policy "Users can insert entries with their user id." on user_access_tokens
  for insert with check (auth.uid() = user_id);

create policy "Users can update their tokens." on user_access_tokens
  for update using (auth.uid() = user_id);

create policy "Users can delete their tokens." on user_access_tokens
  for delete using (auth.uid() = user_id);

-- Query stats

alter table query_stats
  enable row level security;

create policy "Users can only see query stats associated to projects they have access to." on public.query_stats
  for select using (
    query_stats.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can insert query stats associated to projects they have access to." on public.query_stats
  for insert with check (
    query_stats.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can update query stats associated to projects they have access to." on public.query_stats
  for update using (
    query_stats.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );

create policy "Users can delete query stats associated to projects they have access to." on public.query_stats
  for delete using (
    query_stats.project_id in (
      select projects.id from projects
      left join memberships
      on projects.team_id = memberships.team_id
      where memberships.user_id = auth.uid()
    )
  );
