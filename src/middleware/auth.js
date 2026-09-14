const { supabase } = require('../config/supabase');

/**
 * Middleware d'authentification optionnelle.
 * Extrait l'utilisateur du token JWT Supabase si présent.
 * Ne bloque pas les requêtes non authentifiées (les RLS s'en chargent).
 */
async function authOptional(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    req.user = null;
    return next();
  }

  const token = authHeader.replace('Bearer ', '');

  try {
    const { data: { user }, error } = await supabase.auth.getUser(token);

    if (error) {
      req.user = null;
    } else {
      req.user = user;
    }
  } catch {
    req.user = null;
  }

  next();
}

/**
 * Middleware d'authentification obligatoire.
 * Renvoie 401 si le token est absent ou invalide.
 */
async function authRequired(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Token d\'authentification requis' });
  }

  const token = authHeader.replace('Bearer ', '');

  try {
    const { data: { user }, error } = await supabase.auth.getUser(token);

    if (error || !user) {
      return res.status(401).json({ error: 'Token invalide ou expiré' });
    }

    req.user = user;
    next();
  } catch {
    res.status(401).json({ error: 'Erreur d\'authentification' });
  }
}

module.exports = { authOptional, authRequired };
