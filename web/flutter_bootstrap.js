{{flutter_js}}
{{flutter_build_config}}

const loadingStatus = document.getElementById('app-loading-status');

_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    if (loadingStatus) loadingStatus.textContent = 'Starting application…';

    try {
      const appRunner = await engineInitializer.initializeEngine();
      await appRunner.runApp();

      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          document.getElementById('app-loading')?.remove();
        });
      });
    } catch (error) {
      if (loadingStatus) {
        loadingStatus.textContent = 'Unable to start. Please refresh and try again.';
      }
      throw error;
    }
  },
});
