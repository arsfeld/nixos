use std::io::{self, Read};

fn main() -> io::Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    match mrml::parse(&input) {
        Ok(root) => {
            let opts = mrml::prelude::render::Options::default();
            match root.render(&opts) {
                Ok(html) => println!("{}", html),
                Err(e) => eprintln!("Render error: {}", e),
            }
        }
        Err(e) => eprintln!("Parse error: {}", e),
    }

    Ok(())
}