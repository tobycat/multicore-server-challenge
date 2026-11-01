# Every SQL statement. Results are binary; parameters are text arrays, so a whole batch is one Bind.
.include "defs.inc"
.section .rodata

# Shared tail of the list statements: each distinct article is read once per execution, however many
# reads in the batch want it. p(ord,id) = pages, j = jobs, c = counts.
.macro ENRICH_MID
.ascii " ia AS MATERIALIZED (SELECT array_agg(id ORDER BY id) a FROM d),"
.ascii " xa AS MATERIALIZED (SELECT x.id, x.author_id, x.slug, x.title, x.description, x.created_at, x.updated_at FROM articles x WHERE x.id=ANY((SELECT a FROM ia)::int8[])),"
.ascii " ua AS MATERIALIZED (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id=ANY(ARRAY(SELECT DISTINCT author_id FROM xa ORDER BY 1))),"
.ascii " tl AS MATERIALIZED (SELECT at.article_id id, array_agg(tg.name ORDER BY tg.name) n FROM article_tags at JOIN tags tg ON tg.id=at.tag_id WHERE at.article_id=ANY((SELECT a FROM ia)::int8[]) GROUP BY 1),"
.ascii " fc AS MATERIALIZED (SELECT f.article_id id, count(*) n FROM favorites f WHERE f.article_id=ANY((SELECT a FROM ia)::int8[]) GROUP BY 1),"
.ascii " ea AS MATERIALIZED (SELECT array_agg(author_id ORDER BY id) a FROM xa),"
.endm
.macro ENRICH_TAIL
.ascii " e AS (SELECT d.id, d.idx, d.nb, COALESCE(tl.n,'{}') tl, x.author_id, x.slug, x.title, x.description, x.created_at, x.updated_at,"
.ascii " COALESCE(fc.n,0) fc, u.username, u.bio, u.image"
.ascii " FROM d JOIN xa x ON x.id=d.id JOIN ua u ON u.id=x.author_id LEFT JOIN tl ON tl.id=d.id LEFT JOIN fc ON fc.id=d.id),"
.ascii " fl AS MATERIALIZED (SELECT jf.*, ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id=jf.v AND f.article_id=ANY(jf.ids)) fa,"
.ascii " ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=jf.v AND fo.followee_id=ANY(jf.au)) fo FROM jf)"
# Row kinds: 0 an article with its id and author; 1 one job's page as article indexes, with the articles it favorited and the
# authors it follows, which the renderer turns into flags; 2 one job's count.
.ascii " SELECT 0::int4 t, e.idx a, NULL::int8[] pk, NULL::int8[] fa, NULL::int8[] fo, e.id, e.author_id, e.slug, e.title, e.description,"
.ascii " CASE WHEN e.nb THEN (SELECT b.body FROM articles b WHERE b.id=e.id) END body, e.created_at, e.updated_at, e.tl, e.fc, e.username, e.bio, e.image FROM e"
.ascii " UNION ALL SELECT 1::int4, fl.ord, fl.ix, fl.fa, fl.fo, NULL::int8, NULL::int8,"
.ascii " NULL::text,NULL::text,NULL::text,NULL::text,NULL::timestamptz,NULL::timestamptz,NULL::text[],NULL::int8,NULL::text,NULL::text,NULL::text FROM fl"
.ascii " UNION ALL SELECT 2::int4, c.ord, ARRAY[c.n], NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL FROM c"
.endm
.macro ENRICH_ARTICLES
.ascii " , q AS MATERIALIZED (SELECT p.ord, p.id, j.v, j.k, dense_rank() OVER (ORDER BY p.id) idx FROM p JOIN j ON j.ord=p.ord),"
.ascii " d AS MATERIALIZED (SELECT id, idx, bool_or(k=4) nb FROM q GROUP BY id, idx),"
ENRICH_MID
.ascii " jf AS MATERIALIZED (SELECT q.ord, q.v, array_agg(q.id ORDER BY q.id DESC) ids, array_agg(q.idx ORDER BY q.id DESC) ix,"
.ascii " array_agg((SELECT a FROM ea)[q.idx] ORDER BY q.id DESC) au FROM q GROUP BY q.ord, q.v),"
ENRICH_TAIL
.endm

# For lists whose jobs repeat a page: pp(keys,id) holds each distinct page once, pa aggregates it, and each job only joins to it.
.macro ENRICH_PAGES
.ascii ", d AS MATERIALIZED (SELECT s.id, dense_rank() OVER (ORDER BY s.id) idx, false nb FROM (SELECT DISTINCT id FROM pp) s),"
ENRICH_MID
.endm

.globl sql_mega
sql_mega:
# Tag, author and favorited lists. One scan per distinct key gives both its count and every page anyone asked of it.
.ascii "WITH j AS MATERIALIZED (SELECT * FROM unnest($1::int4[],$2::int8[],$3::int4[],$4::int4[],$5::text[]) WITH ORDINALITY AS t(k,v,l,o,s,ord)),"
.ascii " mx AS MATERIALIZED (SELECT max(l+o) m, GREATEST(1000,max(l::int8+o)) lim FROM j),"
.ascii " kk AS MATERIALIZED (SELECT ks.k, ks.s, cardinality(z.ids) n, z.ids[1:(SELECT m FROM mx)] ids FROM (SELECT DISTINCT k, s FROM j) ks CROSS JOIN LATERAL (SELECT CASE ks.k"
.ascii " WHEN 1 THEN ARRAY(SELECT at.article_id FROM article_tags at WHERE at.tag_id=(SELECT tg.id FROM tags tg WHERE tg.name=ks.s) ORDER BY at.article_id DESC LIMIT (SELECT lim FROM mx))"
.ascii " WHEN 2 THEN ARRAY(SELECT a.id FROM articles a WHERE a.author_id=(SELECT au.id FROM users au WHERE au.username=ks.s) ORDER BY a.id DESC LIMIT (SELECT lim FROM mx))"
.ascii " ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id=(SELECT fu.id FROM users fu WHERE fu.username=ks.s) ORDER BY f.article_id DESC LIMIT (SELECT lim FROM mx)) END ids OFFSET 0) z),"
.ascii " pp AS MATERIALIZED (SELECT g.k, g.s, g.l, g.o, e.id FROM (SELECT DISTINCT k, s, l, o FROM j) g JOIN kk ON kk.k=g.k AND kk.s=g.s CROSS JOIN LATERAL unnest(kk.ids[g.o+1:g.o+g.l]) e(id)),"
.ascii " c AS MATERIALIZED (SELECT j.ord, LEAST(kk.n,1000)::int8 n FROM j JOIN kk ON kk.k=j.k AND kk.s=j.s)"
ENRICH_PAGES
.ascii " pa AS MATERIALIZED (SELECT pp.k, pp.s, pp.l, pp.o, array_agg(pp.id ORDER BY pp.id DESC) ids, array_agg(d.idx ORDER BY pp.id DESC) ix, array_agg((SELECT a FROM ea)[d.idx] ORDER BY pp.id DESC) au FROM pp JOIN d ON d.id=pp.id GROUP BY pp.k, pp.s, pp.l, pp.o),"
.ascii " jf AS MATERIALIZED (SELECT j.ord, j.v, pa.ids, pa.ix, pa.au FROM j JOIN pa ON pa.k=j.k AND pa.s=j.s AND pa.l=j.l AND pa.o=j.o),"
ENRICH_TAIL
.byte 0

# The global list: every job pages the same newest articles, and the count is one number.
.globl sql_global
sql_global:
.ascii "WITH j AS MATERIALIZED (SELECT t.k, t.v, t.l, t.o, t.ord FROM unnest($1::int4[],$2::int8[],$3::int4[],$4::int4[],$5::text[]) WITH ORDINALITY AS t(k,v,l,o,s,ord)),"
.ascii " w AS MATERIALIZED (SELECT a.id, row_number() OVER (ORDER BY a.id DESC) rn FROM (SELECT id FROM articles ORDER BY id DESC LIMIT (SELECT coalesce(max(l::int8+o),0) FROM j)) a),"
.ascii " pp AS MATERIALIZED (SELECT g.l, g.o, w.id FROM (SELECT DISTINCT l, o FROM j) g JOIN w ON w.rn>g.o AND w.rn<=g.o::int8+g.l),"
.ascii " cn AS MATERIALIZED (SELECT count(*) n FROM (SELECT 1 FROM articles LIMIT 1000) q),"
.ascii " c AS MATERIALIZED (SELECT j.ord, cn.n FROM j, cn)"
ENRICH_PAGES
.ascii " pa AS MATERIALIZED (SELECT pp.l, pp.o, array_agg(pp.id ORDER BY pp.id DESC) ids, array_agg(d.idx ORDER BY pp.id DESC) ix, array_agg((SELECT a FROM ea)[d.idx] ORDER BY pp.id DESC) au FROM pp JOIN d ON d.id=pp.id GROUP BY pp.l, pp.o),"
.ascii " jf AS MATERIALIZED (SELECT j.ord, j.v, pa.ids, pa.ix, pa.au FROM j JOIN pa ON pa.l=j.l AND pa.o=j.o),"
ENRICH_TAIL
.byte 0

# Article views: the list statement's tail, with none of the branches that find pages and counts.
.globl sql_article
sql_article:
.ascii "WITH j AS MATERIALIZED (SELECT t.k, t.v, t.s, t.ord FROM unnest($1::int4[],$2::int8[],$3::int4[],$4::int4[],$5::text[]) WITH ORDINALITY AS t(k,v,l,o,s,ord)),"
.ascii " p AS MATERIALIZED (SELECT j.ord, a.id FROM j JOIN articles a ON a.slug=j.s),"
.ascii " c AS MATERIALIZED (SELECT 0::int8 ord, 0::int8 n WHERE false)"
ENRICH_ARTICLES
.byte 0

.globl sql_feed
sql_feed:
.ascii "WITH j AS MATERIALIZED (SELECT 5 k, t.v, t.l, t.o, t.ord, t.l+t.o m, ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id=t.v) fl"
.ascii " FROM unnest($1::int8[],$2::int4[],$3::int4[]) WITH ORDINALITY AS t(v,l,o,ord)),"
# hubs: the authors most followed in this batch that have 1000+ articles. A viewer following one has a count of exactly 1000
# and a page that cannot reach below the hub's m-th newest article, so one scan of recent articles replaces per-author reads.
.ascii " b AS MATERIALIZED (SELECT s.f, ARRAY(SELECT x.id FROM articles x WHERE x.author_id=s.f ORDER BY x.id DESC LIMIT s.m) ids FROM"
.ascii " (SELECT g.i f, max(j.m) m FROM j, unnest(j.fl) g(i) GROUP BY g.i HAVING count(*)>=2 ORDER BY count(*) DESC, g.i LIMIT 20) s"
.ascii " WHERE EXISTS (SELECT 1 FROM articles x WHERE x.author_id=s.f ORDER BY x.id DESC OFFSET 999 LIMIT 1)),"
.ascii " sh AS MATERIALIZED (SELECT j.ord, max(b.ids[j.m]) cut FROM j, unnest(j.fl) g(i) JOIN b ON b.f=g.i GROUP BY j.ord),"
.ascii " wq AS MATERIALIZED (SELECT sh.ord, sh.cut FROM sh WHERE sh.cut > (SELECT max(id) FROM articles)-CASE WHEN cardinality($1::int8[])>=32 THEN LEAST(2048,32*cardinality($1::int8[])) ELSE 0 END),"
.ascii " win AS MATERIALIZED (SELECT a.id, a.author_id FROM articles a WHERE a.id>=(SELECT min(cut) FROM wq) ORDER BY a.id DESC LIMIT 32768),"
.ascii " nq AS MATERIALIZED (SELECT j.ord, j.l, j.o, j.fl, sh.ord IS NOT NULL big, sh.cut FROM j LEFT JOIN sh ON sh.ord=j.ord LEFT JOIN wq ON wq.ord=j.ord WHERE wq.ord IS NULL),"
.ascii " fo AS MATERIALIZED (SELECT nq.ord, nq.l, nq.o, nq.big, nq.cut, g.i a FROM nq, unnest(nq.fl) g(i)),"
.ascii " au AS MATERIALIZED (SELECT d.a, cardinality(z.ids) n, z.ids[1:d.mm] ids FROM (SELECT a, bool_and(big) big, min(cut) lo, max(l+o) mm FROM fo GROUP BY a) d CROSS JOIN LATERAL"
.ascii " (SELECT ARRAY(SELECT x.id FROM articles x WHERE x.author_id=d.a AND x.id>=CASE WHEN d.big THEN d.lo ELSE 0 END ORDER BY x.id DESC LIMIT CASE WHEN d.big THEN d.mm ELSE GREATEST(1000,d.mm) END) ids OFFSET 0) z),"
.ascii " fau AS MATERIALIZED (SELECT fo.ord, fo.l, fo.o, au.ids FROM fo JOIN au ON au.a=fo.a),"
.ascii " cu AS MATERIALIZED (SELECT ord, COALESCE(max(ids[l+o]),0) v FROM fau GROUP BY ord),"
.ascii " p AS MATERIALIZED (SELECT r.ord, r.id FROM (SELECT f.ord, f.l, f.o, e.id, row_number() OVER (PARTITION BY f.ord ORDER BY e.id DESC) rn"
.ascii " FROM fau f JOIN cu ON cu.ord=f.ord CROSS JOIN LATERAL unnest(f.ids[1:f.l+f.o]) e(id) WHERE f.ids[1]>=cu.v AND e.id>=cu.v) r WHERE r.rn>r.o AND r.rn<=r.o::int8+r.l"
.ascii " UNION ALL SELECT r.ord, r.id FROM (SELECT q.ord, q.l, q.o, w.id, row_number() OVER (PARTITION BY q.ord ORDER BY w.id DESC) rn"
.ascii " FROM (SELECT j.ord, j.l, j.o, wq.cut, g.i FROM j JOIN wq ON wq.ord=j.ord, unnest(j.fl) g(i)) q JOIN win w ON w.author_id=q.i AND w.id>=q.cut) r WHERE r.rn>r.o AND r.rn<=r.o::int8+r.l),"
.ascii " c AS MATERIALIZED (SELECT wq.ord, 1000::int8 n FROM wq UNION ALL SELECT nq.ord, CASE WHEN nq.big THEN 1000 ELSE LEAST(1000,COALESCE(sum(au.n),0)) END::int8 FROM nq LEFT JOIN fo ON fo.ord=nq.ord LEFT JOIN au ON au.a=fo.a GROUP BY nq.ord, nq.big)"
ENRICH_ARTICLES
.byte 0

.globl sql_comments
sql_comments:
.ascii "SELECT j.ord, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.fol"
.ascii " FROM unnest($1::text[],$2::int8[]) WITH ORDINALITY AS j(s,v,ord) JOIN articles a ON a.slug=j.s"
.ascii " LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,"
.ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id=j.v AND fo.followee_id=c.author_id) fol"
.ascii " FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true"
.asciz " ORDER BY j.ord, c.created_at DESC, c.id DESC"

.globl sql_profile
sql_profile:
.ascii "SELECT j.ord, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id=j.v AND fo.followee_id=u.id)"
.asciz " FROM unnest($1::text[],$2::int8[]) WITH ORDINALITY AS j(s,v,ord) JOIN users u ON u.username=j.s"

.globl sql_user
sql_user:
.asciz "SELECT j.ord, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY AS j(i,ord) JOIN users u ON u.id=j.i"

.globl sql_login
sql_login:
.asciz "SELECT j.ord, u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM unnest($1::text[]) WITH ORDINALITY AS j(e,ord) JOIN users u ON u.email=j.e"

.globl sql_tags
sql_tags:
.asciz "SELECT name FROM tags ORDER BY name"

# ---- writes: one statement per request, so a group needs no round trip between statements.
.macro SLUGIFY x
.ascii "trim(both '-' from lower(regexp_replace(\x, '[^A-Za-z0-9]+', '-', 'g')))"
.endm
.globl sql_w_reg,sql_w_upd,sql_w_fol,sql_w_unfol,sql_w_fav,sql_w_unfav,sql_w_tags,sql_w_art,sql_w_artupd,sql_w_artdel,sql_w_cmt,sql_w_cmtdel
sql_w_reg:
.asciz "INSERT INTO users (username,email,password_hash) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING RETURNING id,username,email,bio,image"
sql_w_upd:
.ascii "UPDATE users SET email=COALESCE($2,email),username=COALESCE($3,username),password_hash=COALESCE($4,password_hash),"
.asciz "bio=COALESCE($5,bio),image=COALESCE($6,image) WHERE id=$1::int8 RETURNING id,username,email,bio,image"
sql_w_fol:
.ascii "WITH u AS (SELECT id,username,bio,image FROM users WHERE username=$2),"
.ascii " i AS (INSERT INTO follows (follower_id,followee_id) SELECT $1::int8,id FROM u ON CONFLICT DO NOTHING)"
.asciz " SELECT username,bio,image FROM u"
sql_w_unfol:
.ascii "WITH u AS (SELECT id,username,bio,image FROM users WHERE username=$2),"
.ascii " i AS (DELETE FROM follows WHERE follower_id=$1::int8 AND followee_id=(SELECT id FROM u))"
.asciz " SELECT username,bio,image FROM u"
sql_w_fav:
.ascii "WITH a AS (SELECT id FROM articles WHERE slug=$2),"
.ascii " i AS (INSERT INTO favorites (user_id,article_id) SELECT $1::int8,id FROM a ON CONFLICT DO NOTHING)"
.asciz " SELECT id FROM a"
sql_w_unfav:
.ascii "WITH a AS (SELECT id FROM articles WHERE slug=$2),"
.ascii " i AS (DELETE FROM favorites WHERE user_id=$1::int8 AND article_id=(SELECT id FROM a))"
.asciz " SELECT id FROM a"
sql_w_tags:
.asciz "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
sql_w_art:
.ascii "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles','id')) id),"
.ascii " i AS (INSERT INTO articles (id,slug,author_id,title,description,body) SELECT n.id,"
SLUGIFY $2
.ascii "||'-'||n.id,$1::int8,$2,$3,$4 FROM n RETURNING id,slug),"
.ascii " g AS (INSERT INTO article_tags (article_id,tag_id) SELECT i.id,t.id FROM i, tags t WHERE t.name=ANY($5::text[]))"
.asciz " SELECT slug FROM i"
sql_w_artupd:
.ascii "WITH c AS (SELECT id,author_id FROM articles WHERE slug=$1),"
.ascii " u AS (UPDATE articles a SET title=COALESCE($2,a.title),description=COALESCE($3,a.description),body=COALESCE($4,a.body),"
.ascii " slug=CASE WHEN $2::text IS NULL THEN a.slug ELSE "
SLUGIFY $2
.ascii "||'-'||a.id END, updated_at=now() FROM c WHERE a.id=c.id AND c.author_id=$5::int8 RETURNING a.slug)"
.asciz " SELECT c.author_id,(SELECT slug FROM u) FROM c"
sql_w_artdel:
.ascii "WITH c AS (SELECT id,author_id FROM articles WHERE slug=$1),"
.ascii " d AS (DELETE FROM articles a USING c WHERE a.id=c.id AND c.author_id=$2::int8)"
.asciz " SELECT author_id FROM c"
sql_w_cmt:
.ascii "WITH a AS (SELECT id FROM articles WHERE slug=$2),"
.ascii " c AS (INSERT INTO comments (article_id,author_id,body) SELECT a.id,$1::int8,$3 FROM a RETURNING id,body,created_at,updated_at,author_id)"
.asciz " SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image FROM c JOIN users u ON u.id=c.author_id"
sql_w_cmtdel:
.ascii "WITH c AS (SELECT c.id,c.author_id FROM comments c JOIN articles a ON a.id=c.article_id WHERE c.id=$1::int8 AND a.slug=$2),"
.ascii " d AS (DELETE FROM comments x USING c WHERE x.id=c.id AND c.author_id=$3::int8)"
.asciz " SELECT author_id FROM c"
