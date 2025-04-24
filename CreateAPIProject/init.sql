-- Table: public.users
CREATE TABLE IF NOT EXISTS public.users
(
    id integer NOT NULL,
    username text COLLATE pg_catalog."default" NOT NULL,
    CONSTRAINT users_pkey PRIMARY KEY (id)
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.users
    OWNER to postgres;

-- PROCEDURE: public.add_new_user(text)
CREATE OR REPLACE PROCEDURE public.add_new_user(
	IN username text)
LANGUAGE 'sql'
AS $BODY$
INSERT INTO users(username) VALUES (username)
$BODY$;
ALTER PROCEDURE public.add_new_user(text)
    OWNER TO postgres;

-- FUNCTION: public.get_user_list()
CREATE OR REPLACE FUNCTION public.get_user_list(
	)
    RETURNS SETOF users 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
BEGIN
	RETURN QUERY
		SELECT id, username FROM users;
END
$BODY$;

ALTER FUNCTION public.get_user_list()
    OWNER TO postgres;

-- FUNCTION: public.get_user_by_id(integer)
CREATE OR REPLACE FUNCTION public.get_user_by_id(
	user_id integer)
    RETURNS SETOF users 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1

AS $BODY$
BEGIN
	RETURN QUERY
		SELECT id, username FROM users WHERE id = user_id;
END
$BODY$;

ALTER FUNCTION public.get_user_by_id(integer)
    OWNER TO postgres;
