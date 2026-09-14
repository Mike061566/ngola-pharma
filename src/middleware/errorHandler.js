/**
 * Middleware centralisé de gestion des erreurs.
 */
function errorHandler(err, req, res, _next) {
  console.error('💥 Erreur:', err.message);

  if (process.env.NODE_ENV !== 'production') {
    console.error(err.stack);
  }

  const status = err.status || 500;
  res.status(status).json({
    error: status === 500 ? 'Erreur interne du serveur' : err.message,
    ...(process.env.NODE_ENV !== 'production' && { stack: err.stack }),
  });
}

module.exports = errorHandler;
