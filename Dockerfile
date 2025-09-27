# Simple Dockerfile for testing
FROM nginx:alpine

# Copy custom nginx configuration to listen on 8080
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Create a simple index.html
RUN echo "<h1>Joker App - Test Container</h1><p>Running on port 8080</p>" > /usr/share/nginx/html/index.html

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

# Start nginx
CMD ["nginx", "-g", "daemon off;"]