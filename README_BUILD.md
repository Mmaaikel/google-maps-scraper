<!-- First build! -->
docker buildx build --platform linux/arm64 -f Dockerfile.arm -t mac-studio-van-horecainsights:55000/google-maps-scraper:arm . && docker buildx build --platform linux/amd64 -f Dockerfile.arm -t mac-studio-van-horecainsights:55000/google-maps-scraper:amd .

<!-- Then push -->
docker push mac-studio-van-horecainsights:55000/google-maps-scraper:arm && docker push mac-studio-van-horecainsights:55000/google-maps-scraper:amd