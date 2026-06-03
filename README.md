# test-globle

扁平化蓝色渐变地球 - Three.js r173 + Vue 3

## 本地运行

```bash
cd frontend
npm install
npm run dev
```

浏览器打开 http://localhost:3000/ 。GeoJSON 从 `frontend/public/ne_110m_admin_0_countries.json` 静态加载，无需启动 Python 后端。

## GitHub Pages 在线预览

地址：https://tymontong.github.io/3D-globe/

**首次或 Pages 仍显示 README 时**，在仓库 [Settings → Pages](https://github.com/TymonTong/test-globle/settings/pages) 中：

1. **Build and deployment → Source** 选 **GitHub Actions**（不要选 “Deploy from a branch / main / root”）。
2. 推送代码后，在 **Actions** 页等待 `Deploy GitHub Pages` 工作流跑完（约 1～2 分钟）。
3. 刷新 https://tymontong.github.io/3D-globe/ 即可看到蓝色地球。

> 若仓库改名，Pages 路径会变为 `/<新仓库名>/`；workflow 会自动用当前仓库名作为 `base`，无需手改路径。
