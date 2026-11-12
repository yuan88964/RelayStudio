import { render } from 'preact';
import './styles/theme.css';
import './styles/popovers-dialogs.css';
import { App } from './App';

const root = document.getElementById('app');
if (root) {
  render(<App />, root);
}
