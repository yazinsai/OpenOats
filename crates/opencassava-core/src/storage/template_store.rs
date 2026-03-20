use crate::models::MeetingTemplate;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Serialize, Deserialize)]
struct StorageFormat {
    version: u32,
    templates: Vec<MeetingTemplate>,
}

pub struct TemplateStore {
    path: PathBuf,
    templates: Vec<MeetingTemplate>,
}

impl TemplateStore {
    pub fn load() -> Self {
        Self::load_from(Self::default_path())
    }

    pub fn default_path() -> PathBuf {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("OpenCassava")
            .join("templates.json")
    }

    pub fn load_from(path: PathBuf) -> Self {
        let templates = if let Ok(data) = std::fs::read_to_string(&path) {
            if let Ok(stored) = serde_json::from_str::<StorageFormat>(&data) {
                let mut ts = stored.templates;
                for built_in in MeetingTemplate::built_ins() {
                    if !ts.iter().any(|t| t.id == built_in.id) {
                        ts.push(built_in);
                    }
                }
                ts
            } else {
                MeetingTemplate::built_ins()
            }
        } else {
            MeetingTemplate::built_ins()
        };

        let store = Self { path, templates };
        store.save();
        store
    }

    pub fn templates(&self) -> &[MeetingTemplate] {
        &self.templates
    }

    pub fn get(&self, id: uuid::Uuid) -> Option<&MeetingTemplate> {
        self.templates.iter().find(|t| t.id == id)
    }

    pub fn add(&mut self, template: MeetingTemplate) {
        self.templates.push(template);
        self.save();
    }

    pub fn update(&mut self, template: MeetingTemplate) {
        if let Some(t) = self.templates.iter_mut().find(|t| t.id == template.id) {
            *t = template;
            self.save();
        }
    }

    pub fn delete(&mut self, id: uuid::Uuid) {
        if let Some(idx) = self
            .templates
            .iter()
            .position(|t| t.id == id && !t.is_built_in)
        {
            self.templates.remove(idx);
            self.save();
        }
    }

    fn save(&self) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let stored = StorageFormat {
            version: 1,
            templates: self.templates.clone(),
        };
        if let Ok(json) = serde_json::to_string_pretty(&stored) {
            let _ = std::fs::write(&self.path, json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn loads_built_ins_when_no_file() {
        let dir = tempdir().unwrap();
        let store = TemplateStore::load_from(dir.path().join("templates.json"));
        assert_eq!(store.templates().len(), 6);
    }

    #[test]
    fn custom_template_persists() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("templates.json");
        let mut store = TemplateStore::load_from(path.clone());
        let t = crate::models::MeetingTemplate {
            id: uuid::Uuid::new_v4(),
            name: "My Template".into(),
            icon: "star".into(),
            system_prompt: "Be helpful.".into(),
            is_built_in: false,
        };
        store.add(t);
        let store2 = TemplateStore::load_from(path);
        assert!(store2.templates().iter().any(|x| x.name == "My Template"));
    }
}
