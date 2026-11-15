把前端构建产物放这里：

    pnpm install && pnpm build
    ./scripts/sync-web.sh            # 或手动 cp -r dist/. <这个目录>/

必须包含 index.html 与 assets/。这个文件本身可以删掉。
